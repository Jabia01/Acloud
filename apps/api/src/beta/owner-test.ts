import {createHash} from 'node:crypto';
import {ForbiddenException, ConflictException} from '@nestjs/common';
import type {PoolClient} from 'pg';
import type {Principal} from '../auth/auth.service';
import type {UploadInput} from '../uploads/input';
import {resourceHash} from './config';

const uuid=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
export const OWNER_TEST_FILE_BYTES=32*1024*1024;
export const OWNER_TEST_TOTAL_BYTES=64*1024*1024;
export const OWNER_TEST_FILES=2;
const deny=()=>new ForbiddenException('Private staging test unavailable');
export function ownerTestBinding(e:NodeJS.ProcessEnv){
  return createHash('sha256').update(JSON.stringify([resourceHash(e),e.API_PUBLIC_ORIGIN,e.B2_S3_ENDPOINT])).digest('hex');
}
export function ownerTestBound(p:Principal,e:NodeJS.ProcessEnv=process.env){return ownerTestConfigured(e)||e.OWNER_DEVICE_TEST_ACCOUNT_ID===p.userId;}
export function ownerTestTTL(ttl:number){
  if(!ownerTestConfigured())return ttl;
  const cfg=ownerTestConfiguration()!;
  const remaining=Math.floor((cfg.end-Date.now())/1000);
  if(remaining<1)throw deny();
  return Math.min(ttl,remaining);
}
export function ownerTestConfigured(e:NodeJS.ProcessEnv=process.env){return e.OWNER_DEVICE_TEST_ENABLED==='true';}
export function ownerTestConfiguration(e:NodeJS.ProcessEnv=process.env){
  if(e.OWNER_DEVICE_TEST_ENABLED!==undefined&&!['true','false'].includes(e.OWNER_DEVICE_TEST_ENABLED))throw deny();
  if(!ownerTestConfigured(e))return null;
  const off=['BETA_ENABLED','BETA_ALLOW_REAL_MEDIA','BETA_ALLOW_B2','BETA_ALLOW_PAYMENTS','BETA_ALLOW_FREE_UP_SPACE','BETA_ALLOW_SUPPORT_TOOLS','CUSTOMER_REGISTRATION_ENABLED','BILLING_ENABLED','ENABLE_FREE_UP_SPACE','ACCOUNT_DELETION_ENABLED','ACCOUNT_DELETION_EXECUTION_ENABLED','RETENTION_EXECUTION_ENABLED','RESTORE_ENABLED'];
  if(e.NODE_ENV!=='production'||e.APP_ENV!=='staging'||e.STORAGE_ENVIRONMENT!=='staging'||e.STORAGE_PROVIDER!=='backblaze_b2'||off.some(k=>e[k]!=='false')||e.NODE_TLS_REJECT_UNAUTHORIZED==='0')throw deny();
  if(!e.B2_BUCKET_NAME||e.B2_BUCKET_NAME==='acloud-prod-media'||e.B2_BUCKET_NAME!==e.BETA_EXPECTED_BUCKET||e.OWNER_DEVICE_TEST_RESOURCE_HASH!==ownerTestBinding(e))throw deny();
  for(const key of ['API_PUBLIC_ORIGIN','B2_S3_ENDPOINT']){const u=new URL(e[key]!);if(u.protocol!=='https:'||u.username||u.password||u.search||u.hash||u.pathname!=='/')throw deny();}
  const profile=e.OWNER_DEVICE_TEST_PROFILE??'smoke';
  if(!['smoke','project'].includes(profile))throw deny();
  const maxDuration=profile==='project'?31*24*3600*1000:24*3600*1000;
  const maxFiles=profile==='project'?100:OWNER_TEST_FILES;
  const maxBytes=profile==='project'?1024*1024*1024:OWNER_TEST_TOTAL_BYTES;
  const account=e.OWNER_DEVICE_TEST_ACCOUNT_ID??'',device=e.OWNER_DEVICE_TEST_DEVICE_ID??'';
  const start=Date.parse(e.OWNER_DEVICE_TEST_STARTS_AT??''),end=Date.parse(e.OWNER_DEVICE_TEST_EXPIRES_AT??'');
  if(!uuid.test(account)||!uuid.test(device)||!Number.isFinite(start)||!Number.isFinite(end)||end<=start||end-start>maxDuration)throw deny();
  return {account,device,start,end,maxFiles,maxBytes};
}
export function ownerTestIdentity(p:Principal,e:NodeJS.ProcessEnv=process.env,now=Date.now()){
  const cfg=ownerTestConfiguration(e);
  if(!cfg||now<cfg.start||now>=cfg.end||p.userId!==cfg.account||p.deviceId!==cfg.device||!p.sessionId)throw deny();
  return cfg;
}
// Revalidate the live session under the same user lock used by upload reservation.
export async function ownerTestAccess(c:PoolClient,p:Principal,operations:string[],e:NodeJS.ProcessEnv=process.env){
  const cfg=ownerTestIdentity(p,e);
  const live=await c.query(`SELECT s.id FROM sessions s JOIN users u ON u.id=s.user_id JOIN devices d ON d.id=s.device_id AND d.user_id=u.id
    WHERE s.id=$1 AND s.user_id=$2 AND s.device_id=$3 AND s.revoked_at IS NULL AND s.expires_at>now()
    AND d.revoked_at IS NULL AND u.status='ACTIVE' AND u.privacy_state='ACTIVE' AND u.email_verified_at IS NOT NULL AND u.abuse_review=false`,[p.sessionId,cfg.account,cfg.device]);
  if(!live.rowCount)throw deny();
  const switches=await c.query('SELECT name,blocked FROM beta_switches WHERE name=ANY($1::text[])',[operations]);
  if(operations.some(name=>!switches.rows.some(r=>r.name===name&&r.blocked===false)))throw deny();
  return cfg;
}
export async function ownerTestUpload(c:PoolClient,p:Principal,input?:UploadInput & {key?:string}){
  const cfg=await ownerTestAccess(c,p,['uploads','multipart']);
  if(!input)return;
  if(!['image','video','test'].includes(input.mediaType)||!input.multipart||(input.deviceId??p.deviceId)!==cfg.device||input.size<1||input.size>OWNER_TEST_FILE_BYTES)throw deny();
  const old=await c.query('SELECT u.id,a.device_id,a.created_at FROM upload_sessions u JOIN assets a ON a.id=u.asset_id WHERE u.user_id=$1 AND u.idempotency_key=$2',[p.userId,input.key]);
  if(old.rows[0]){const a=old.rows[0];if(a.device_id!==cfg.device||new Date(a.created_at).getTime()<cfg.start||new Date(a.created_at).getTime()>=cfg.end)throw deny();return;}
  // Count cancelled/failed attempts too. Existing per-user transaction lock serializes reservations.
  const usage=(await c.query('SELECT count(*)::int AS count,COALESCE(sum(expected_size_bytes),0)::text AS bytes FROM assets WHERE user_id=$1 AND created_at >= $2',[p.userId,new Date(cfg.start)])).rows[0];
  if(Number(usage.count)>=cfg.maxFiles||BigInt(usage.bytes)+BigInt(input.size)>BigInt(cfg.maxBytes))throw new ConflictException('Private test allowance reached');
}
export async function ownerTestAsset(c:PoolClient,p:Principal,id:string,operations:string[]){
  const cfg=await ownerTestAccess(c,p,operations);
  const r=(await c.query(`SELECT a.id FROM assets a JOIN upload_sessions s ON s.asset_id=a.id AND s.user_id=a.user_id
    WHERE a.id=$1 AND a.user_id=$2 AND a.device_id=$3 AND a.created_at >= $4 AND a.created_at < $5
    AND a.storage_provider='backblaze_b2' AND a.privacy_deleted_at IS NULL AND a.expected_size_bytes BETWEEN 1 AND $6`,[id,p.userId,cfg.device,new Date(cfg.start),new Date(cfg.end),OWNER_TEST_FILE_BYTES])).rows[0];
  if(!r)throw deny();
}
export async function ownerTestRestoreIds(c:PoolClient,p:Principal){
  const cfg=await ownerTestAccess(c,p,['restore','downloads']);
  return (await c.query(`SELECT a.id FROM assets a JOIN upload_sessions s ON s.asset_id=a.id AND s.user_id=a.user_id
    WHERE a.user_id=$1 AND a.device_id=$2 AND a.created_at >= $3 AND a.created_at < $4
    AND a.storage_provider='backblaze_b2' AND a.status='PROTECTED' AND a.privacy_deleted_at IS NULL
    AND a.media_type IN ('image','video') AND a.expected_size_bytes BETWEEN 1 AND $5 ORDER BY a.created_at LIMIT $6`,[p.userId,cfg.device,new Date(cfg.start),new Date(cfg.end),OWNER_TEST_FILE_BYTES,cfg.maxFiles])).rows.map(r=>r.id as string);
}
