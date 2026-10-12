import {ownerTestConfigured,ownerTestAsset,ownerTestBound,ownerTestTTL} from '../beta/owner-test';
import {BetaPolicy} from '../beta/policy';import {betaConfiguration} from '../beta/config';
import {limitSetting} from '../hardening/config';
import {EntitlementService} from '../billing/entitlement';
import { BadRequestException, ForbiddenException, ConflictException, ServiceUnavailableException, GoneException, Inject, Injectable, NotFoundException, UnauthorizedException } from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import type { PoolClient } from 'pg';
import { DatabaseService } from '../database.service';
import type { Principal } from '../auth/auth.service';
import { ObjectStorageProvider, type VerificationResult } from './storage';
import { defaultQuota, downloadTTL, uploadTTL, partSize, sessionTTL, type UploadInput } from './input';
export const safeAsset = (r: Record<string,any>) => ({id:r.id,mediaType:r.media_type,status:r.status,sizeBytes:r.verified_size_bytes === null ? null : Number(r.verified_size_bytes)});
const safeUpload = (r: Record<string,any>) => ({id:r.id,assetId:r.asset_id,status:r.status,expiresAt:new Date(r.expires_at).toISOString(),errorCode:r.last_error_code ?? null,transferMode:r.transfer_mode ?? 'single',partSizeBytes:r.part_size_bytes ? Number(r.part_size_bytes) : null});
@Injectable()
export class UploadService {
  constructor(@Inject(DatabaseService) private readonly db: DatabaseService, @Inject(ObjectStorageProvider) private readonly storage: ObjectStorageProvider,@Inject(BetaPolicy) private readonly beta:BetaPolicy=new BetaPolicy(db)) {}
  private async lock(c: PoolClient, p: Principal) {
    // User-first ordering matches auth revocation/reset. Recheck the guard's principal.
    const user = await c.query("SELECT id FROM users WHERE id=$1 AND status='ACTIVE' AND privacy_state='ACTIVE' FOR UPDATE",[p.userId]);
    if (!user.rowCount) throw new UnauthorizedException('Authentication required');
    const auth = await c.query(`SELECT s.id FROM sessions s LEFT JOIN devices d ON d.id=s.device_id WHERE s.id=$1 AND s.user_id=$2
      AND s.revoked_at IS NULL AND s.expires_at>now() AND (s.device_id IS NULL OR d.revoked_at IS NULL)`,[p.sessionId,p.userId]);
    if (!auth.rowCount) throw new UnauthorizedException('Authentication required');
    await EntitlementService.lock(c,p.userId);
  }
  private async audit(c: PoolClient,p: Principal,id: string,event: string,code: string|null = null) {
    await c.query('INSERT INTO upload_audit_events(id,user_id,upload_session_id,event,error_code) VALUES($1,$2,$3,$4,$5)',[randomUUID(),p.userId,id,event,code]);
  }
  private async expire(c: PoolClient,p: Principal) {
    const expired = await c.query(`UPDATE upload_sessions SET status=CASE WHEN status='CANCELLED' THEN 'CANCELLED' ELSE 'EXPIRED' END,reservation_released_at=now(),verification_lease=NULL,verification_lease_until=NULL,last_error_code='UPLOAD_EXPIRED'
      WHERE user_id=$1 AND reservation_released_at IS NULL AND expires_at<=now() AND (verification_lease_until IS NULL OR verification_lease_until<=now()) RETURNING id,asset_id,expected_size_bytes,status`,[p.userId]);
    for (const r of expired.rows) {
      await c.query("UPDATE assets SET status=$2,updated_at=now() WHERE id=$1 AND status<>'PROTECTED'",[r.asset_id,r.status]);
      await c.query('UPDATE development_entitlements SET reserved_bytes=reserved_bytes-$2 WHERE user_id=$1',[p.userId,r.expected_size_bytes]);
      await this.audit(c,p,r.id,'EXPIRED');
    }
  }
  async create(p: Principal,input: UploadInput,idempotencyKey: string) {
    if(ownerTestConfigured()&&this.storage.identity().provider!=='backblaze_b2')throw new ForbiddenException('Private test provider unavailable');
    if(betaConfiguration().enabled&&this.storage.identity().provider!=='backblaze_b2')throw new ForbiddenException('Accepted B2 provider required');
    const deviceId=input.deviceId ?? (input.multipart ? p.deviceId : null);
    const row = await this.db.transaction(async c => {
      if(betaConfiguration().enabled)await this.beta.lock(c);
      await this.lock(c,p); await this.expire(c,p);
      await this.beta.upload(p,{...input,key:idempotencyKey} as UploadInput,c);
      if (deviceId && deviceId!==p.deviceId) throw new NotFoundException('Device unavailable');
      if (deviceId && !(await c.query('SELECT id FROM devices WHERE id=$1 AND user_id=$2 AND revoked_at IS NULL',[deviceId,p.userId])).rowCount) throw new NotFoundException('Device unavailable');
      const found = await c.query('SELECT * FROM upload_sessions WHERE user_id=$1 AND idempotency_key=$2',[p.userId,idempotencyKey]);
      if (found.rows[0]) {
        if (found.rows[0].request_hash !== input.requestHash) throw new ConflictException('Idempotency key reused with different input');
        await this.checkDevice(c,p,found.rows[0].asset_id);
        return found.rows[0];
      }
      if(process.env.NODE_ENV==='production'&&!(await c.query('SELECT id FROM users WHERE id=$1 AND email_verified_at IS NOT NULL AND abuse_review=false',[p.userId])).rowCount)throw new UnauthorizedException('Verified account required');
      if(Number((await c.query('SELECT count(*) n FROM upload_sessions WHERE user_id=$1 AND reservation_released_at IS NULL',[p.userId])).rows[0].n)>=limitSetting('MAX_PENDING_UPLOADS',1000,10000))throw new ConflictException('Upload queue limit reached');
      if(input.multipart&&Number((await c.query("SELECT count(*) n FROM upload_sessions WHERE user_id=$1 AND transfer_mode='multipart' AND reservation_released_at IS NULL",[p.userId])).rows[0].n)>=limitSetting('MAX_PARALLEL_MULTIPART',10,100))throw new ConflictException('Multipart concurrency limit reached');
      const reserved = await c.query('UPDATE development_entitlements SET reserved_bytes=reserved_bytes+$2 WHERE user_id=$1 AND protected_bytes+reserved_bytes+$2<=quota_bytes RETURNING user_id',[p.userId,input.size]);
      if (!reserved.rowCount) throw new ConflictException('Quota exceeded');
      const assetId=randomUUID(),id=randomUUID(),key=`objects/${randomUUID().slice(0,8)}/${randomUUID()}`;
      await c.query("INSERT INTO assets(id,user_id,device_id,media_type,expected_size_bytes,expected_checksum,storage_object_key,storage_provider,storage_binding,source_library_id,status) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,'QUEUED')",[assetId,p.userId,deviceId,input.mediaType,input.size,input.checksum,key,this.storage.identity().provider,this.storage.identity().binding,input.libraryId??null]);
      const created = await c.query(`INSERT INTO upload_sessions(id,user_id,asset_id,idempotency_key,request_hash,status,expected_size_bytes,expected_checksum,expires_at,transfer_mode,part_size_bytes)
        VALUES($1,$2,$3,$4,$5,'QUEUED',$6,$7,now()+($8 * interval '1 second'),$9,$10) RETURNING *`,[id,p.userId,assetId,idempotencyKey,input.requestHash,input.size,input.checksum,input.multipart ? sessionTTL() : uploadTTL(),input.multipart?'multipart':'single',input.multipart?partSize():null]);
      await this.audit(c,p,id,'CREATED'); return created.rows[0];
    });
    if(betaConfiguration().enabled&&!await this.storage.isHealthy())throw new ServiceUnavailableException('Storage unavailable');
    if (row.transfer_mode==='multipart') return {...safeUpload(row),authorization:null};
    if (['PROTECTED','VERIFYING','UPLOADED','CANCELLED','EXPIRED'].includes(row.status)) return {...safeUpload(row),authorization:null};
    const asset = await this.db.query('SELECT storage_object_key,storage_provider,storage_binding FROM assets WHERE id=$1 AND user_id=$2',[row.asset_id,p.userId]);
    const ttl=Math.min(uploadTTL(),Math.floor((new Date(row.expires_at).getTime()-Date.now())/1000));
    if (ttl<1) throw new GoneException('Upload expired');
    // Durable reservation before signing: timeout retries reuse the same row/key.
    this.storage.assertBinding(asset.rows[0]!.storage_provider,asset.rows[0]!.storage_binding);
    const authorization=await this.storage.createUploadAuthorization(asset.rows[0]!.storage_object_key,Number(row.expected_size_bytes),row.expected_checksum,ttl);
    return {...safeUpload(row),authorization};
  }
  async getUpload(p: Principal,id: string) {
    const r=(await this.db.query('SELECT * FROM upload_sessions WHERE id=$1 AND user_id=$2',[id,p.userId])).rows[0];
    if (!r) { void this.db.query("INSERT INTO operational_security_events(id,code) VALUES($1,'UPLOAD_TARGET_UNAVAILABLE')",[randomUUID()]).catch(()=>{}); throw new NotFoundException('Upload unavailable'); }
    await this.db.transaction(async c=>{await this.lock(c,p); await this.owned(c,p,id);}); return safeUpload(r);
  }
  async start(p: Principal,id: string) {
    await this.beta.upload(p);
    return this.db.transaction(async c => {
      await this.lock(c,p); await this.expire(c,p);
      const row=(await c.query('SELECT * FROM upload_sessions WHERE id=$1 AND user_id=$2 FOR UPDATE',[id,p.userId])).rows[0];
      if (!row) throw new NotFoundException('Upload unavailable');
      await this.checkDevice(c,p,row.asset_id);
      if (['QUEUED','FAILED'].includes(row.status)) {
        await c.query("UPDATE upload_sessions SET status='UPLOADING' WHERE id=$1",[id]);
        await c.query("UPDATE assets SET status='UPLOADING',updated_at=now() WHERE id=$1",[row.asset_id]);
        await this.audit(c,p,id,'TRANSFER_INTENT');
      }
      return safeUpload((await c.query('SELECT * FROM upload_sessions WHERE id=$1',[id])).rows[0]);
    });
  }
  async complete(p: Principal,id: string) { return this.completeInternal(p,id); }
  // Internal worker entry only; never exposed by a customer controller.
  async completeForOperations(userId: string,id: string,authorize: (c:PoolClient)=>Promise<void>) {
    return this.completeInternal({userId,sessionId:'',deviceId:null},id,authorize);
  }
  private async completeInternal(p: Principal,id: string,authorize?: (c:PoolClient)=>Promise<void>) {
    const lock=async(c:PoolClient)=>{if(!authorize)return this.lock(c,p);await authorize(c);if(!(await c.query("SELECT id FROM users WHERE id=$1 AND status='ACTIVE' AND privacy_state='ACTIVE' FOR UPDATE",[p.userId])).rowCount)throw new UnauthorizedException('Account unavailable');await c.query('SELECT user_id FROM development_entitlements WHERE user_id=$1 FOR UPDATE',[p.userId]);};
    const claim=await this.db.transaction(async c => {
      await lock(c); await this.expire(c,p);
      const r=(await c.query('SELECT * FROM upload_sessions WHERE id=$1 AND user_id=$2 FOR UPDATE',[id,p.userId])).rows[0];
      if (!r) { void this.db.query("INSERT INTO operational_security_events(id,code) VALUES($1,'UPLOAD_TARGET_UNAVAILABLE')",[randomUUID()]).catch(()=>{}); throw new NotFoundException('Upload unavailable'); }
      if(!authorize)await this.checkDevice(c,p,r.asset_id);
      if (['PROTECTED','CANCELLED','EXPIRED'].includes(r.status)) return {row:r,lease:null,key:null};
      if (new Date(r.expires_at).getTime()<=Date.now()) return {row:{...r,status:'EXPIRED',last_error_code:'UPLOAD_EXPIRED'},lease:null,key:null};
      if (r.verification_lease_until && new Date(r.verification_lease_until).getTime()>Date.now()) return {row:r,lease:null,key:null};
      if(r.transfer_mode==='multipart' && !r.completed_version_id) throw new ConflictException('Multipart completion required');
      const lease=randomUUID();
      // This is a client receipt claim, not proof that bytes exist or are intact.
      await c.query("UPDATE upload_sessions SET status='UPLOADED' WHERE id=$1",[id]);
      await c.query("UPDATE assets SET status='UPLOADED',updated_at=now() WHERE id=$1",[r.asset_id]);
      await this.audit(c,p,id,'CLIENT_RECEIPT_CLAIM');
      const updated=await c.query("UPDATE upload_sessions SET status='VERIFYING',verification_lease=$2,verification_lease_until=now()+interval '16 minutes' WHERE id=$1 RETURNING *",[id,lease]);
      await c.query("UPDATE assets SET status='VERIFYING',updated_at=now() WHERE id=$1",[r.asset_id]);
      await this.audit(c,p,id,'VERIFICATION_STARTED');
      const asset=(await c.query('SELECT storage_object_key,storage_provider,storage_binding FROM assets WHERE id=$1',[r.asset_id])).rows[0];
      this.storage.assertBinding(asset.storage_provider,asset.storage_binding);
      return {row:updated.rows[0],lease,key:asset.storage_object_key as string};
    });
    if (!claim.lease || !claim.key) return safeUpload(claim.row);
    let result: VerificationResult;
    try { result=await this.storage.verifyObject(claim.key,Number(claim.row.expected_size_bytes),claim.row.expected_checksum,claim.row.completed_version_id ?? undefined); }
    catch { result={ok:false,code:'STORAGE_UNAVAILABLE'}; }
    // Defend the lifecycle even if a future provider violates its interface contract.
    if (result.ok && result.sizeBytes !== Number(claim.row.expected_size_bytes)) result={ok:false,code:'SIZE_MISMATCH',sizeBytes:result.sizeBytes};
    if (result.ok && result.checksum !== claim.row.expected_checksum) result={ok:false,code:'CHECKSUM_MISMATCH',sizeBytes:result.sizeBytes,checksum:result.checksum};
    if (result.ok && claim.row.completed_version_id && result.versionId!==claim.row.completed_version_id) result={ok:false,code:'IMMUTABILITY_UNAVAILABLE'};
    if (result.ok && (!result.versionId || result.versionId==='null')) result={ok:false,code:'IMMUTABILITY_UNAVAILABLE'};
    return this.db.transaction(async c => {
      await lock(c);
      const r=(await c.query('SELECT *,expires_at>now() AS live,verification_lease_until>now() AS lease_live FROM upload_sessions WHERE id=$1 AND user_id=$2 FOR UPDATE',[id,p.userId])).rows[0];
      if (r.verification_lease!==claim.lease || !r.lease_live || r.status!=='VERIFYING') return safeUpload(r);
      if (!r.live) {
        await c.query('UPDATE upload_sessions SET verification_lease_until=now() WHERE id=$1',[id]);
        await this.expire(c,p);
        return {...safeUpload(r),status:'EXPIRED',errorCode:'UPLOAD_EXPIRED'};
      }
      await c.query(`INSERT INTO asset_verifications(id,asset_id,attempt_id,storage_size_bytes,storage_checksum,verification_status,verified_at,error_code)
        VALUES($1,$2,$3,$4,$5,$6,$7,$8)`,[randomUUID(),r.asset_id,claim.lease,result.sizeBytes??null,result.checksum??null,result.ok?'SUCCEEDED':'FAILED',result.ok?new Date():null,result.ok?null:result.code]);
      if (result.ok) {
        const move=await c.query('UPDATE development_entitlements SET reserved_bytes=reserved_bytes-$2,protected_bytes=protected_bytes+$2 WHERE user_id=$1 AND reserved_bytes>=$2 RETURNING user_id',[p.userId,r.expected_size_bytes]);
        if (!move.rowCount) throw new Error('Reservation inconsistent');
        await c.query("UPDATE assets SET status='PROTECTED',protected_at=now(),updated_at=now(),verified_size_bytes=$2,storage_version_id=$3 WHERE id=$1",[r.asset_id,result.sizeBytes,result.versionId]);
        await c.query("UPDATE upload_sessions SET status='PROTECTED',completed_at=now(),reservation_released_at=now(),verification_lease=NULL,verification_lease_until=NULL,last_error_code=NULL WHERE id=$1",[id]);
        await this.audit(c,p,id,'VERIFIED_PROTECTED');
      } else {
        await c.query("UPDATE assets SET status='FAILED',updated_at=now() WHERE id=$1",[r.asset_id]);
        await c.query("UPDATE upload_sessions SET status='FAILED',verification_lease=NULL,verification_lease_until=NULL,last_error_code=$2 WHERE id=$1",[id,result.code]);
        await this.audit(c,p,id,'VERIFICATION_FAILED',result.code);
      }
      return safeUpload((await c.query('SELECT * FROM upload_sessions WHERE id=$1',[id])).rows[0]);
    });
  }
  async cancel(p: Principal,id: string) {
    return this.db.transaction(async c => {
      await this.lock(c,p); await this.expire(c,p);
      const r=(await c.query('SELECT * FROM upload_sessions WHERE id=$1 AND user_id=$2 FOR UPDATE',[id,p.userId])).rows[0];
      if (!r) { void this.db.query("INSERT INTO operational_security_events(id,code) VALUES($1,'UPLOAD_TARGET_UNAVAILABLE')",[randomUUID()]).catch(()=>{}); throw new NotFoundException('Upload unavailable'); }
      await this.checkDevice(c,p,r.asset_id);
      if (r.status==='PROTECTED') throw new ConflictException('Protected assets cannot be cancelled');
      if (!r.reservation_released_at && r.status !== 'CANCELLED') {
        await c.query("UPDATE assets SET status='CANCELLED',updated_at=now() WHERE id=$1",[r.asset_id]);
        await c.query("UPDATE upload_sessions SET status='CANCELLED',verification_lease=NULL,verification_lease_until=NULL WHERE id=$1",[id]);
        await this.audit(c,p,id,'CANCELLED');
      }
      // Keep the reservation until expiry: an already signed PUT may still land.
      return safeUpload((await c.query('SELECT * FROM upload_sessions WHERE id=$1',[id])).rows[0]);
    });
  }
  private async checkDevice(c: PoolClient,p: Principal,assetId: string) {
    if(ownerTestBound(p))await ownerTestAsset(c,p,assetId,['uploads','multipart']);
    const a=(await c.query('SELECT device_id FROM assets WHERE id=$1',[assetId])).rows[0];
    if(a?.device_id && a.device_id!==p.deviceId) throw new NotFoundException('Upload unavailable');
  }
  private async owned(c: PoolClient,p: Principal,id: string) {
    const r=(await c.query('SELECT u.*,a.storage_object_key,a.storage_provider,a.storage_binding FROM upload_sessions u JOIN assets a ON a.id=u.asset_id WHERE u.id=$1 AND u.user_id=$2 FOR UPDATE OF u',[id,p.userId])).rows[0];
    if(!r) throw new NotFoundException('Upload unavailable'); await this.checkDevice(c,p,r.asset_id); return r;
  }
  private activeMultipart(r: Record<string,any>) {
    this.storage.assertBinding(r.storage_provider,r.storage_binding);
    if(r.transfer_mode!=='multipart') throw new ConflictException('Multipart required');
    if(new Date(r.expires_at).getTime()<=Date.now() || ['CANCELLED','EXPIRED'].includes(r.status)) throw new GoneException('Upload unavailable');
  }
  async multipartStart(p: Principal,id: string) {
    await this.beta.upload(p);await this.beta.open('multipart');
    return this.db.transaction(async c=>{
      await this.lock(c,p); await this.expire(c,p); const r=await this.owned(c,p,id); this.activeMultipart(r);
      if(r.status==='PROTECTED' || r.completed_version_id) return safeUpload(r);
      if(!r.multipart_upload_id) {
        // Hold the serialized user/session lock. A crash here can orphan a storage upload;
        // bucket lifecycle must abort unreferenced incomplete uploads after retention.
        const upload=await this.storage.beginMultipart(r.storage_object_key);
        await c.query("UPDATE upload_sessions SET multipart_upload_id=$2,status='UPLOADING' WHERE id=$1",[id,upload]);
        await c.query("UPDATE assets SET status='UPLOADING',updated_at=now() WHERE id=$1",[r.asset_id]);
        await this.audit(c,p,id,'MULTIPART_STARTED'); r.multipart_upload_id=upload; r.status='UPLOADING';
      }
      return safeUpload(r);
    });
  }
  async authorizePart(p: Principal,id: string,number: number,body: unknown) {
    await this.beta.upload(p);await this.beta.open('multipart');
    if(!body || typeof body!=='object' || Array.isArray(body)) throw new BadRequestException('Invalid part');
    const b=body as Record<string,unknown>;
    if(Object.keys(b).some(k=>!['size_bytes','checksum_sha256'].includes(k)) || typeof b.checksum_sha256!=='string' || !/^[a-f0-9]{64}$/.test(b.checksum_sha256)) throw new BadRequestException('Invalid part');
    return this.db.transaction(async c=>{
      await this.lock(c,p); await this.expire(c,p); const r=await this.owned(c,p,id); this.activeMultipart(r);
      if(!r.multipart_upload_id || r.completed_version_id || !['UPLOADING','FAILED'].includes(r.status)) throw new ConflictException('Transfer unavailable');
      const count=Math.ceil(Number(r.expected_size_bytes)/Number(r.part_size_bytes));
      if(!Number.isSafeInteger(number) || number<1 || number>count || number>10000) throw new BadRequestException('Invalid part');
      const size=Math.min(Number(r.part_size_bytes),Number(r.expected_size_bytes)-(number-1)*Number(r.part_size_bytes));
      if(b.size_bytes!==size) throw new BadRequestException('Invalid part size');
      const old=(await c.query('SELECT * FROM upload_parts WHERE upload_session_id=$1 AND part_number=$2',[id,number])).rows[0];
      if(old && (old.expected_checksum!==b.checksum_sha256 || Number(old.expected_size_bytes)!==size)) throw new ConflictException('Part identity changed');
      await c.query('INSERT INTO upload_parts(upload_session_id,part_number,expected_size_bytes,expected_checksum) VALUES($1,$2,$3,$4) ON CONFLICT DO NOTHING',[id,number,size,b.checksum_sha256]);
      const ttl=Math.min(uploadTTL(),Math.floor((new Date(r.expires_at).getTime()-Date.now())/1000));
      if(ttl<1) throw new GoneException('Upload expired');
      return this.storage.authorizePart(r.storage_object_key,r.multipart_upload_id,number,size,b.checksum_sha256 as string,ownerTestTTL(ttl));
    });
  }
  private async reconcileParts(c: PoolClient,r: Record<string,any>) {
    const actual=await this.storage.listParts(r.storage_object_key,r.multipart_upload_id);
    const declared=(await c.query('SELECT * FROM upload_parts WHERE upload_session_id=$1 ORDER BY part_number',[r.id])).rows;
    const byNumber=new Map(declared.map(d=>[d.part_number,d]));
    const valid=[];
    for(const part of actual) {
      const d=byNumber.get(part.partNumber);
      if(!d || Number(d.expected_size_bytes)!==part.sizeBytes || (part.checksum && part.checksum!==Buffer.from(d.expected_checksum,'hex').toString('base64'))) throw new ConflictException('Storage part mismatch');
      await c.query('UPDATE upload_parts SET storage_etag=$3,completed_at=now() WHERE upload_session_id=$1 AND part_number=$2',[r.id,part.partNumber,part.etag]); valid.push(part);
    }
    return valid.sort((a,b)=>a.partNumber-b.partNumber);
  }
  async parts(p: Principal,id: string) {
    return this.db.transaction(async c=>{
      await this.lock(c,p); const r=await this.owned(c,p,id); this.activeMultipart(r);
      if(r.completed_version_id || r.status==='PROTECTED') return {completed:true,parts:[]};
      if(!r.multipart_upload_id) return {completed:false,parts:[]};
      const parts=await this.reconcileParts(c,r);
      return {completed:false,parts:parts.map(p=>({partNumber:p.partNumber,sizeBytes:p.sizeBytes}))};
    });
  }
  async completeMultipart(p: Principal,id: string) {
    return this.db.transaction(async c=>{
      await this.lock(c,p); await this.expire(c,p); const r=await this.owned(c,p,id); this.activeMultipart(r);
      if(r.completed_version_id || r.status==='PROTECTED') return safeUpload(r);
      if(!r.multipart_upload_id) throw new ConflictException('Multipart not started');
      // Recover storage completion acknowledged before a database/process crash.
      // Key is random and create-only; version pin is immutable for all later verification.
      let version:string|undefined;
      try { const m=await this.storage.getObjectMetadata(r.storage_object_key); if(m.sizeBytes===Number(r.expected_size_bytes)) version=m.versionId; }
      catch { /* Missing object is expected until completion. */ }
      if(!version) {
        const parts=await this.reconcileParts(c,r);
        const count=Math.ceil(Number(r.expected_size_bytes)/Number(r.part_size_bytes));
        if(parts.length!==count || parts.some((p,i)=>p.partNumber!==i+1) || parts.reduce((n,p)=>n+p.sizeBytes,0)!==Number(r.expected_size_bytes)) throw new ConflictException('Parts incomplete');
        try { version=await this.storage.completeMultipart(r.storage_object_key,r.multipart_upload_id,parts); }
        catch { throw new ServiceUnavailableException('Storage unavailable'); }
      }
      await c.query("UPDATE upload_sessions SET status='UPLOADED',completed_version_id=$2 WHERE id=$1",[id,version]);
      await c.query("UPDATE assets SET status='UPLOADED',updated_at=now() WHERE id=$1",[r.asset_id]); await this.audit(c,p,id,'MULTIPART_COMPLETED');
      return safeUpload({...r,status:'UPLOADED'});
    });
  }
  async inventory(p: Principal, query: Record<string, unknown>) {
    if (Object.values(query).some(v => typeof v !== 'string') || Object.keys(query).some(k => !['mediaType','limit','cursor'].includes(k))) throw new BadRequestException('Invalid filters');
    const media = query.mediaType ?? null;
    if (media !== null && !['image','video','test'].includes(String(media))) throw new BadRequestException('Invalid media type');
    const limit = query.limit === undefined ? 30 : Number(query.limit);
    if (!Number.isInteger(limit) || limit < 1 || limit > 100 || (query.limit !== undefined && !/^[1-9][0-9]{0,2}$/.test(String(query.limit)))) throw new BadRequestException('Invalid page size');
    let anchor: string | null = null;
    if (query.cursor !== undefined) {
      try {
        if (typeof query.cursor !== 'string' || query.cursor.length > 256 || !/^[A-Za-z0-9_-]+$/.test(query.cursor)) throw new Error();
        const value = JSON.parse(Buffer.from(query.cursor, 'base64url').toString('utf8'));
        if (value.v !== 1 || value.media !== media || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value.id)) throw new Error();
        anchor = value.id;
      } catch { throw new BadRequestException('Invalid cursor'); }
    }
    return this.db.transaction(async c => {
      await this.lock(c,p);
      if (anchor && !(await c.query("SELECT id FROM assets WHERE id=$1 AND user_id=$2 AND status='PROTECTED' AND ($3::text IS NULL OR media_type=$3)",[anchor,p.userId,media])).rowCount) throw new BadRequestException('Invalid cursor');
      // Compare timestamps inside PostgreSQL, retaining microsecond precision.
      const whereMedia = media === null ? '' : ' AND a.media_type=$4';
      const values: unknown[] = [p.userId,anchor,limit+1];
      if (media !== null) values.push(media);
      const result = await c.query(`SELECT a.id,a.media_type,a.status,a.verified_size_bytes,a.protected_at,d.id AS device_id,d.display_name
        FROM assets a LEFT JOIN devices d ON d.id=a.device_id AND d.user_id=a.user_id
        WHERE a.user_id=$1 AND a.status='PROTECTED'${whereMedia}
        AND ($2::uuid IS NULL OR (a.protected_at,a.id)<(SELECT protected_at,id FROM assets WHERE id=$2 AND user_id=$1))
        ORDER BY a.protected_at DESC,a.id DESC LIMIT $3`,values);
      const rows = result.rows.slice(0,limit);
      return {items:rows.map(r => ({...safeAsset(r),protectedAt:r.protected_at,captureDate:null,durationSeconds:null,device:r.device_id ? {id:r.device_id,displayName:r.display_name} : null})),
        nextCursor:result.rows.length>limit ? Buffer.from(JSON.stringify({v:1,id:rows.at(-1)!.id,media})).toString('base64url') : null};
    });
  }
  async summary(p: Principal, kind: 'storage' | 'backup') {
    return this.db.transaction(async c => {
      await this.lock(c,p); await this.expire(c,p);
      const totals = (await c.query(`SELECT count(*)::int AS count,COALESCE(sum(verified_size_bytes),0)::text AS bytes,
        count(*) FILTER (WHERE media_type='image')::int AS photos,count(*) FILTER (WHERE media_type='video')::int AS videos,
        max(protected_at) AS latest FROM assets WHERE user_id=$1 AND status='PROTECTED'`,[p.userId])).rows[0];
      const logical=(await c.query(`SELECT count(*)::int count,count(*) FILTER(WHERE media_type='image')::int photos,count(*) FILTER(WHERE media_type='video')::int videos FROM (
        SELECT id,media_type FROM media_manifest_summary WHERE user_id=$1 AND protection_state='FULLY_PROTECTED'
        UNION ALL SELECT a.id,a.media_type FROM assets a WHERE a.user_id=$1 AND a.status='PROTECTED' AND NOT EXISTS(SELECT 1 FROM media_manifest_resources r WHERE r.asset_id=a.id)
      ) logical`,[p.userId])).rows[0];
      const uploads = (await c.query(`SELECT COALESCE(sum(expected_size_bytes) FILTER (WHERE reservation_released_at IS NULL),0)::text AS reserved,
        count(*) FILTER (WHERE reservation_released_at IS NULL)::int AS reservations,
        count(*) FILTER (WHERE status IN ('QUEUED','UPLOADING','UPLOADED','VERIFYING') AND reservation_released_at IS NULL)::int AS active,
        count(*) FILTER (WHERE status='FAILED')::int AS failed,count(*) FILTER (WHERE status='EXPIRED')::int AS stale
        FROM upload_sessions WHERE user_id=$1`,[p.userId])).rows[0];
      const entitlement = (await c.query('SELECT * FROM development_entitlements WHERE user_id=$1',[p.userId])).rows[0];
      if (BigInt(totals.bytes)!==BigInt(entitlement.protected_bytes) || BigInt(uploads.reserved)!==BigInt(entitlement.reserved_bytes)) throw new ServiceUnavailableException('Storage summary unavailable');
      const quota=Number(entitlement.quota_bytes),protectedBytes=Number(totals.bytes),reservedBytes=Number(uploads.reserved);
      if (![quota,protectedBytes,reservedBytes].every(Number.isSafeInteger)) throw new ServiceUnavailableException('Storage summary unavailable');
      if (kind==='storage') return {quotaBytes:quota,protectedBytes,reservedBytes,remainingBytes:Math.max(0,quota-protectedBytes-reservedBytes),overQuota:protectedBytes+reservedBytes>quota,assetCount:logical.count,photoCount:logical.photos,videoCount:logical.videos};
      const devices = (await c.query('SELECT count(*)::int AS count FROM devices WHERE user_id=$1 AND revoked_at IS NULL',[p.userId])).rows[0];
      return {protectedAssetCount:logical.count,lastProtectedAt:totals.latest,activeUploads:uploads.active,reservedUploads:uploads.reservations,failedUploads:uploads.failed,staleUploads:uploads.stale,activeDeviceCount:devices.count};
    });
  }
  async asset(p: Principal,id: string) {
    return this.db.transaction(async c => {
      await this.lock(c,p);
      const r=(await c.query('SELECT a.*,d.display_name FROM assets a LEFT JOIN devices d ON d.id=a.device_id AND d.user_id=a.user_id WHERE a.id=$1 AND a.user_id=$2',[id,p.userId])).rows[0];
      if (!r) { void this.db.query("INSERT INTO operational_security_events(id,code) VALUES($1,'UPLOAD_TARGET_UNAVAILABLE')",[randomUUID()]).catch(()=>{}); throw new NotFoundException('Asset unavailable'); }
      return {...safeAsset(r),protectedAt:r.protected_at,createdAt:r.created_at,captureDate:null,durationSeconds:null,device:r.device_id ? {id:r.device_id,displayName:r.display_name} : null};
    });
  }
  async integrity(p:Principal,id:string){return this.db.transaction(async c=>{await this.lock(c,p);const r=(await c.query("SELECT a.id,a.media_type,a.status,a.verified_size_bytes,a.expected_checksum,v.id AS verification_id,v.storage_checksum,v.storage_size_bytes FROM assets a JOIN asset_verifications v ON v.asset_id=a.id AND v.verification_status='SUCCEEDED' WHERE a.id=$1 AND a.user_id=$2 AND a.status='PROTECTED' AND a.privacy_deleted_at IS NULL ORDER BY v.verified_at DESC LIMIT 1",[id,p.userId])).rows[0];if(!r||r.storage_checksum!==r.expected_checksum||r.storage_size_bytes!==r.verified_size_bytes)throw new NotFoundException('Verified asset unavailable');return{id:r.id,status:'PROTECTED',mediaType:r.media_type,sizeBytes:Number(r.verified_size_bytes),checksum:r.storage_checksum,verificationId:r.verification_id};});}
  async download(p: Principal,id: string) {
    await this.beta.open('downloads');
    return this.db.transaction(async c => {
      await this.lock(c,p);
      if(ownerTestBound(p))await ownerTestAsset(c,p,id,['downloads']);
      const r=(await c.query('SELECT * FROM assets WHERE id=$1 AND user_id=$2',[id,p.userId])).rows[0];
      if (!r) { void this.db.query("INSERT INTO operational_security_events(id,code) VALUES($1,'UPLOAD_TARGET_UNAVAILABLE')",[randomUUID()]).catch(()=>{}); throw new NotFoundException('Asset unavailable'); }
      if (r.status!=='PROTECTED') throw new ConflictException('Asset is not protected');
      this.storage.assertBinding(r.storage_provider,r.storage_binding);
      // Local signing while holding the same user lock as revocation closes the guard/sign gap.
      // Previously issued storage capabilities still live until their short expiry.
      return this.storage.createDownloadAuthorization(r.storage_object_key,r.storage_version_id,ownerTestTTL(downloadTTL()));
    });
  }
}
