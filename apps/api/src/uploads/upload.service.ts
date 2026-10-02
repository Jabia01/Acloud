import { ConflictException, GoneException, Inject, Injectable, NotFoundException, UnauthorizedException } from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import type { PoolClient } from 'pg';
import { DatabaseService } from '../database.service';
import type { Principal } from '../auth/auth.service';
import { ObjectStorageProvider, type VerificationResult } from './storage';
import { defaultQuota, downloadTTL, uploadTTL, type UploadInput } from './input';
const safeAsset = (r: Record<string,any>) => ({id:r.id,mediaType:r.media_type,status:r.status,sizeBytes:r.verified_size_bytes === null ? null : Number(r.verified_size_bytes)});
const safeUpload = (r: Record<string,any>) => ({id:r.id,assetId:r.asset_id,status:r.status,expiresAt:new Date(r.expires_at).toISOString(),errorCode:r.last_error_code ?? null});
@Injectable()
export class UploadService {
  constructor(@Inject(DatabaseService) private readonly db: DatabaseService, @Inject(ObjectStorageProvider) private readonly storage: ObjectStorageProvider) {}
  private async lock(c: PoolClient, p: Principal) {
    // User-first ordering matches auth revocation/reset. Recheck the guard's principal.
    const user = await c.query("SELECT id FROM users WHERE id=$1 AND status='ACTIVE' FOR UPDATE",[p.userId]);
    if (!user.rowCount) throw new UnauthorizedException('Authentication required');
    const auth = await c.query(`SELECT s.id FROM sessions s LEFT JOIN devices d ON d.id=s.device_id WHERE s.id=$1 AND s.user_id=$2
      AND s.revoked_at IS NULL AND s.expires_at>now() AND (s.device_id IS NULL OR d.revoked_at IS NULL)`,[p.sessionId,p.userId]);
    if (!auth.rowCount) throw new UnauthorizedException('Authentication required');
    await c.query('INSERT INTO development_entitlements(user_id,quota_bytes) VALUES($1,$2) ON CONFLICT(user_id) DO NOTHING',[p.userId,defaultQuota()]);
    await c.query('SELECT user_id FROM development_entitlements WHERE user_id=$1 FOR UPDATE',[p.userId]);
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
    const row = await this.db.transaction(async c => {
      await this.lock(c,p); await this.expire(c,p);
      if (input.deviceId && !(await c.query('SELECT id FROM devices WHERE id=$1 AND user_id=$2 AND revoked_at IS NULL',[input.deviceId,p.userId])).rowCount) throw new NotFoundException('Device unavailable');
      const found = await c.query('SELECT * FROM upload_sessions WHERE user_id=$1 AND idempotency_key=$2',[p.userId,idempotencyKey]);
      if (found.rows[0]) {
        if (found.rows[0].request_hash !== input.requestHash) throw new ConflictException('Idempotency key reused with different input');
        return found.rows[0];
      }
      const reserved = await c.query('UPDATE development_entitlements SET reserved_bytes=reserved_bytes+$2 WHERE user_id=$1 AND protected_bytes+reserved_bytes+$2<=quota_bytes RETURNING user_id',[p.userId,input.size]);
      if (!reserved.rowCount) throw new ConflictException('Quota exceeded');
      const assetId=randomUUID(),id=randomUUID(),key=`objects/${randomUUID().slice(0,8)}/${randomUUID()}`;
      await c.query("INSERT INTO assets(id,user_id,device_id,media_type,expected_size_bytes,expected_checksum,storage_object_key,status) VALUES($1,$2,$3,$4,$5,$6,$7,'QUEUED')",[assetId,p.userId,input.deviceId,input.mediaType,input.size,input.checksum,key]);
      const created = await c.query(`INSERT INTO upload_sessions(id,user_id,asset_id,idempotency_key,request_hash,status,expected_size_bytes,expected_checksum,expires_at)
        VALUES($1,$2,$3,$4,$5,'QUEUED',$6,$7,now()+($8 * interval '1 second')) RETURNING *`,[id,p.userId,assetId,idempotencyKey,input.requestHash,input.size,input.checksum,uploadTTL()]);
      await this.audit(c,p,id,'CREATED'); return created.rows[0];
    });
    if (['PROTECTED','VERIFYING','UPLOADED','CANCELLED','EXPIRED'].includes(row.status)) return {...safeUpload(row),authorization:null};
    const asset = await this.db.query('SELECT storage_object_key FROM assets WHERE id=$1 AND user_id=$2',[row.asset_id,p.userId]);
    const ttl=Math.min(uploadTTL(),Math.floor((new Date(row.expires_at).getTime()-Date.now())/1000));
    if (ttl<1) throw new GoneException('Upload expired');
    // Durable reservation before signing: timeout retries reuse the same row/key.
    const authorization=await this.storage.createUploadAuthorization(asset.rows[0]!.storage_object_key,Number(row.expected_size_bytes),row.expected_checksum,ttl);
    return {...safeUpload(row),authorization};
  }
  async getUpload(p: Principal,id: string) {
    const r=(await this.db.query('SELECT * FROM upload_sessions WHERE id=$1 AND user_id=$2',[id,p.userId])).rows[0];
    if (!r) throw new NotFoundException('Upload unavailable'); return safeUpload(r);
  }
  async start(p: Principal,id: string) {
    return this.db.transaction(async c => {
      await this.lock(c,p); await this.expire(c,p);
      const row=(await c.query('SELECT * FROM upload_sessions WHERE id=$1 AND user_id=$2 FOR UPDATE',[id,p.userId])).rows[0];
      if (!row) throw new NotFoundException('Upload unavailable');
      if (['QUEUED','FAILED'].includes(row.status)) {
        await c.query("UPDATE upload_sessions SET status='UPLOADING' WHERE id=$1",[id]);
        await c.query("UPDATE assets SET status='UPLOADING',updated_at=now() WHERE id=$1",[row.asset_id]);
        await this.audit(c,p,id,'TRANSFER_INTENT');
      }
      return safeUpload((await c.query('SELECT * FROM upload_sessions WHERE id=$1',[id])).rows[0]);
    });
  }
  async complete(p: Principal,id: string) {
    const claim=await this.db.transaction(async c => {
      await this.lock(c,p); await this.expire(c,p);
      const r=(await c.query('SELECT * FROM upload_sessions WHERE id=$1 AND user_id=$2 FOR UPDATE',[id,p.userId])).rows[0];
      if (!r) throw new NotFoundException('Upload unavailable');
      if (['PROTECTED','CANCELLED','EXPIRED'].includes(r.status)) return {row:r,lease:null,key:null};
      if (new Date(r.expires_at).getTime()<=Date.now()) return {row:{...r,status:'EXPIRED',last_error_code:'UPLOAD_EXPIRED'},lease:null,key:null};
      if (r.verification_lease_until && new Date(r.verification_lease_until).getTime()>Date.now()) return {row:r,lease:null,key:null};
      const lease=randomUUID();
      // This is a client receipt claim, not proof that bytes exist or are intact.
      await c.query("UPDATE upload_sessions SET status='UPLOADED' WHERE id=$1",[id]);
      await c.query("UPDATE assets SET status='UPLOADED',updated_at=now() WHERE id=$1",[r.asset_id]);
      await this.audit(c,p,id,'CLIENT_RECEIPT_CLAIM');
      const updated=await c.query("UPDATE upload_sessions SET status='VERIFYING',verification_lease=$2,verification_lease_until=now()+interval '60 seconds' WHERE id=$1 RETURNING *",[id,lease]);
      await c.query("UPDATE assets SET status='VERIFYING',updated_at=now() WHERE id=$1",[r.asset_id]);
      await this.audit(c,p,id,'VERIFICATION_STARTED');
      const asset=(await c.query('SELECT storage_object_key FROM assets WHERE id=$1',[r.asset_id])).rows[0];
      return {row:updated.rows[0],lease,key:asset.storage_object_key as string};
    });
    if (!claim.lease || !claim.key) return safeUpload(claim.row);
    let result: VerificationResult;
    try { result=await this.storage.verifyObject(claim.key,Number(claim.row.expected_size_bytes),claim.row.expected_checksum); }
    catch { result={ok:false,code:'STORAGE_UNAVAILABLE'}; }
    // Defend the lifecycle even if a future provider violates its interface contract.
    if (result.ok && result.sizeBytes !== Number(claim.row.expected_size_bytes)) result={ok:false,code:'SIZE_MISMATCH',sizeBytes:result.sizeBytes};
    if (result.ok && result.checksum !== claim.row.expected_checksum) result={ok:false,code:'CHECKSUM_MISMATCH',sizeBytes:result.sizeBytes,checksum:result.checksum};
    if (result.ok && (!result.versionId || result.versionId==='null')) result={ok:false,code:'IMMUTABILITY_UNAVAILABLE'};
    return this.db.transaction(async c => {
      await this.lock(c,p);
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
      if (!r) throw new NotFoundException('Upload unavailable');
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
  async asset(p: Principal,id: string) {
    const r=(await this.db.query('SELECT * FROM assets WHERE id=$1 AND user_id=$2',[id,p.userId])).rows[0];
    if (!r) throw new NotFoundException('Asset unavailable'); return safeAsset(r);
  }
  async download(p: Principal,id: string) {
    const r=await this.db.transaction(async c => {
      await this.lock(c,p);
      const r=(await c.query('SELECT * FROM assets WHERE id=$1 AND user_id=$2',[id,p.userId])).rows[0];
      if (!r) throw new NotFoundException('Asset unavailable');
      if (r.status!=='PROTECTED') throw new ConflictException('Asset is not protected'); return r;
    });
    return this.storage.createDownloadAuthorization(r.storage_object_key,r.storage_version_id,downloadTTL());
  }
}
