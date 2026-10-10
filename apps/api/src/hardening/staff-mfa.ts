import {Inject,Injectable,UnauthorizedException} from '@nestjs/common';
import {createCipheriv,createDecipheriv,createHmac,createHash,randomBytes,randomUUID,timingSafeEqual,createPublicKey,verify} from 'node:crypto';
import type {PoolClient} from 'pg';
import {DatabaseService} from '../database.service';
export function totp(secret:Buffer,step:number,digits=6){const b=Buffer.alloc(8);b.writeBigUInt64BE(BigInt(step));const h=createHmac('sha1',secret).update(b).digest(),offset=h[h.length-1]!&15;return String((h.readUInt32BE(offset)&0x7fffffff)%10**digits).padStart(digits,'0');}
function encryptionKey(){const value=process.env.MFA_ENCRYPTION_KEY;if(!value||!/^[a-f0-9]{64}$/.test(value))throw new Error('MFA key unavailable');return Buffer.from(value,'hex');}
export function encryptMFA(secret:Buffer,adminId:string){const iv=randomBytes(12),c=createCipheriv('aes-256-gcm',encryptionKey(),iv);c.setAAD(Buffer.from(adminId));const data=Buffer.concat([c.update(secret),c.final()]);return Buffer.concat([iv,c.getAuthTag(),data]).toString('base64url');}
function decryptMFA(value:string,adminId:string){const b=Buffer.from(value,'base64url');if(b.length<48||b.length>128)throw new Error();const d=createDecipheriv('aes-256-gcm',encryptionKey(),b.subarray(0,12));d.setAAD(Buffer.from(adminId));d.setAuthTag(b.subarray(12,28));return Buffer.concat([d.update(b.subarray(28)),d.final()]);}
export abstract class PasskeyVerifier{abstract assertion(value:unknown,expected:{challengeHash:string;origin:string;rpId:string;credentialKey:string;publicKey:JsonWebKey;counter:number}):number;}
// Narrow ES256 assertion verifier. Enrollment is controlled out-of-band; no unverified browser key registration.
export class ES256PasskeyVerifier extends PasskeyVerifier{
 assertion(value:unknown,e:{challengeHash:string;origin:string;rpId:string;credentialKey:string;publicKey:JsonWebKey;counter:number}){
  const a=value as any;if(!a||a.id!==e.credentialKey||a.type!=='public-key')throw new Error();
  for(const key of ['clientDataJSON','authenticatorData','signature'])if(typeof a.response?.[key]!=='string'||a.response[key].length>16384||!/^[A-Za-z0-9_-]+$/.test(a.response[key]))throw new Error();
  const client=Buffer.from(a.response.clientDataJSON,'base64url'),data=JSON.parse(client.toString('utf8')),auth=Buffer.from(a.response.authenticatorData,'base64url'),sig=Buffer.from(a.response.signature,'base64url');
  if(data.type!=='webauthn.get'||data.origin!==e.origin||data.crossOrigin===true||typeof data.challenge!=='string'||createHash('sha256').update(data.challenge).digest('hex')!==e.challengeHash||auth.length!==37||(auth[32]!&5)!==5||!timingSafeEqual(auth.subarray(0,32),createHash('sha256').update(e.rpId).digest()))throw new Error();
  const counter=auth.readUInt32BE(33);if((e.counter>0||counter>0)&&counter<=e.counter)throw new Error();
  if(e.publicKey.kty!=='EC'||e.publicKey.crv!=='P-256'||e.publicKey.d)throw new Error();
  const key=createPublicKey({key:e.publicKey as any,format:'jwk'});if(!verify('sha256',Buffer.concat([auth,createHash('sha256').update(client).digest()]),key,sig))throw new Error();return counter;
 }
}
@Injectable() export class StaffMFAService{
 private verifier:PasskeyVerifier=new ES256PasskeyVerifier();
 constructor(@Inject(DatabaseService)private db:DatabaseService){}
 async challenge(adminId:string){const id=randomUUID(),challenge=randomBytes(32).toString('base64url');await this.db.query("INSERT INTO staff_challenges(id,admin_id,challenge_hash,expires_at) VALUES($1,$2,$3,now()+interval '2 minutes')",[id,adminId,createHash('sha256').update(challenge).digest('hex')]);const credentials=(await this.db.query("SELECT credential_key FROM staff_credentials WHERE admin_id=$1 AND kind='PASSKEY' AND revoked_at IS NULL",[adminId])).rows;return{allowCredentials:credentials.map(c=>({id:c.credential_key,type:'public-key'})),challengeId:id,challenge,rpId:process.env.STAFF_RP_ID,userVerification:'required',timeout:120000};}
 async validate(c:PoolClient,adminId:string,b:Record<string,any>):Promise<string|null>{
  const credentials=(await c.query('SELECT * FROM staff_credentials WHERE admin_id=$1 AND revoked_at IS NULL ORDER BY id FOR UPDATE',[adminId])).rows;
  if(!credentials.length){if(process.env.NODE_ENV==='production'||process.env.ADMIN_MFA_REQUIRED==='true')throw new UnauthorizedException('Invalid credentials');return null;}
  try{
   if(typeof b.otp==='string'&&/^\d{6}$/.test(b.otp))for(const credential of credentials.filter(x=>x.kind==='TOTP')){
    const secret=decryptMFA(credential.encrypted_secret,adminId),now=Math.floor(Date.now()/30000);let accepted:number|null=null;
    for(const step of [now-1,now,now+1])if(step>Number(credential.last_step)&&timingSafeEqual(Buffer.from(totp(secret,step)),Buffer.from(b.otp)))accepted=step;
    secret.fill(0);if(accepted!==null){await c.query('UPDATE staff_credentials SET last_step=$2 WHERE id=$1',[credential.id,accepted]);return credential.id;}
   }
   if(b.assertion&&typeof b.challengeId==='string'){
    const challenge=(await c.query('SELECT * FROM staff_challenges WHERE id=$1 AND admin_id=$2 AND used_at IS NULL AND expires_at>now() FOR UPDATE',[b.challengeId,adminId])).rows[0];
    const credential=credentials.find(x=>x.kind==='PASSKEY'&&x.credential_key===b.assertion.id);if(!challenge||!credential||!process.env.STAFF_ORIGIN||!process.env.STAFF_RP_ID)throw new Error();
    const counter=this.verifier.assertion(b.assertion,{challengeHash:challenge.challenge_hash,origin:process.env.STAFF_ORIGIN,rpId:process.env.STAFF_RP_ID,credentialKey:credential.credential_key,publicKey:credential.public_key,counter:Number(credential.sign_count)});
    await c.query('UPDATE staff_challenges SET used_at=now() WHERE id=$1',[challenge.id]);await c.query('UPDATE staff_credentials SET sign_count=$2 WHERE id=$1',[credential.id,counter]);return credential.id;
   }
  }catch{throw new UnauthorizedException('Invalid credentials');}
  throw new UnauthorizedException('Invalid credentials');
 }
}
