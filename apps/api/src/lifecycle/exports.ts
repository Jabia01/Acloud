import {uuid} from '../auth/input';
import { Inject, Injectable, UnauthorizedException, ForbiddenException, NotFoundException, ConflictException } from '@nestjs/common';
import { createCipheriv, createDecipheriv, createHmac, randomBytes, timingSafeEqual } from 'node:crypto';
import { DatabaseService } from '../database.service';
import type { Principal } from '../auth/auth.service';
import { lifecyclePolicy, sha } from './policy';
const categories = [
    ['account', 'SELECT id,email,email_verified_at,created_at FROM users WHERE id=$1'],
    ['lifecycle', 'SELECT user_id AS id,state,version,updated_at FROM account_lifecycle WHERE user_id=$1'],
    ['devices', 'SELECT id,display_name,platform,created_at,revoked_at FROM devices WHERE user_id=$1'],
    ['sessions', 'SELECT id,created_at,expires_at,revoked_at FROM sessions WHERE user_id=$1'],
    ['entitlement', 'SELECT user_id AS id,quota_bytes,protected_bytes,reserved_bytes FROM development_entitlements WHERE user_id=$1'],
    ['subscription', 'SELECT id,status,billing_interval,current_period_start,current_period_end,cancel_at_period_end FROM subscriptions WHERE user_id=$1'],
    ['billing', 'SELECT id,amount_minor,currency,status,paid_at FROM billing_transactions WHERE user_id=$1'],
    ['assets', 'SELECT id,media_type,status,verified_size_bytes,protected_at,privacy_deleted_at FROM assets WHERE user_id=$1'],
    ['mediaManifests', 'SELECT id,manifest_version,kind,policy,protection_state,required_count,protected_count,source_changed FROM media_manifest_summary WHERE user_id=$1'],
    ['manifestResources', 'SELECT id,manifest_id,ordinal,role,resource_type,uti,required,class,expected_size,expected_sha256 FROM media_manifest_resources WHERE user_id=$1'],
    ['backupHistory', 'SELECT id,status,created_at,expires_at,completed_at FROM upload_sessions WHERE user_id=$1'],
    ['restoreHistory', 'SELECT id,code,duration_ms,retry_count,created_at FROM restore_events WHERE user_id=$1'],
    ['accountEvents', 'SELECT id,event,created_at FROM auth_audit_events WHERE user_id=$1'],
    ['privacyRequests', 'SELECT id,state,created_at,expires_at FROM privacy_exports WHERE user_id=$1'],
    ['deletionRequests', 'SELECT id,state,not_before,created_at,finished_at FROM deletion_requests WHERE user_id=$1']
] as const;
function key() { const v = process.env.PRIVACY_EXPORT_KEY ?? (process.env.NODE_ENV !== 'production' ? process.env.MFA_ENCRYPTION_KEY : undefined); if (!v || !/^[a-f0-9]{64}$/.test(v))
    throw new Error('Private export encryption key required'); return Buffer.from(v, 'hex'); }
function encrypt(raw: string, aad: string) { const iv = randomBytes(12), c = createCipheriv('aes-256-gcm', key(), iv); c.setAAD(Buffer.from(aad)); const bytes = Buffer.concat([c.update(raw), c.final()]); return Buffer.concat([iv, c.getAuthTag(), bytes]).toString('base64url'); }
function decrypt(value: string, aad: string) { const raw = Buffer.from(value, 'base64url'); if (raw.length < 28 || raw.length > 4 * 1024 * 1024)
    throw new Error('Export chunk bound'); const c = createDecipheriv('aes-256-gcm', key(), raw.subarray(0, 12)); c.setAAD(Buffer.from(aad)); c.setAuthTag(raw.subarray(12, 28)); return Buffer.concat([c.update(raw.subarray(28)), c.final()]).toString(); }
@Injectable()
export class LifecycleExportService {
    ensureAvailable(){const bytes=key();bytes.fill(0);}
    constructor(
    @Inject(DatabaseService)
    private db: DatabaseService) { }
    async build(user: string, id: string) {
        const batch = lifecyclePolicy().exportBatch;
        return this.db.transaction(async (c) => {
            const u = (await c.query("SELECT id FROM users WHERE id=$1 AND status='ACTIVE' AND privacy_state='ACTIVE' FOR SHARE", [user])).rows[0];
            if (!u)
                throw new UnauthorizedException();
            const exp = (await c.query("SELECT * FROM privacy_exports WHERE id=$1 AND user_id=$2 AND state='PENDING' AND expires_at>now() FOR UPDATE", [id, user])).rows[0];
            if (!exp)
                return false;
            await c.query('INSERT INTO privacy_export_jobs(id,user_id,expires_at) VALUES($1,$2,$3) ON CONFLICT DO NOTHING', [id, user, exp.expires_at]);
            const job = (await c.query('SELECT * FROM privacy_export_jobs WHERE id=$1 FOR UPDATE', [id])).rows[0];
            if (job.category >= categories.length) {
                const chunks = (await c.query('SELECT sequence,category,item_count,sha256 FROM privacy_export_chunks WHERE export_id=$1 ORDER BY sequence', [id])).rows;
                // A manifest of bounded chunk descriptors, never raw account rows. Upper bound prevents amplification.
                if (chunks.length > 10000)
                    throw new ConflictException('Export manifest bound; support review required');
                const generated = new Date().toISOString(), manifest = { exportId: id, schemaVersion: 2, generatedAt: generated, expiresAt: exp.expires_at, rawMediaIncluded: false, itemCount: Number(job.item_count), files: chunks.map(r => ({ sequence: r.sequence, category: r.category, itemCount: r.item_count, sha256: r.sha256 })) };
                await c.query("UPDATE privacy_export_jobs SET state='READY',generated_at=now(),manifest=$2 WHERE id=$1", [id, JSON.stringify(manifest)]);
                await c.query("UPDATE privacy_exports SET state='READY',payload=NULL WHERE id=$1", [id]);
                return false;
            }
            const [category, sql] = categories[job.category]!;
            const rows = (await c.query(`SELECT * FROM (${sql}) owned WHERE ($2::uuid IS NULL OR id>$2) ORDER BY id LIMIT $3`, [user, job.cursor_id, batch])).rows;
            if (rows.length) {
                const sequence = (await c.query('SELECT COALESCE(max(sequence),-1)+1 n FROM privacy_export_chunks WHERE export_id=$1', [id])).rows[0].n;
                const raw = rows.map(r => JSON.stringify(r)).join('\n') + '\n';
                if (Buffer.byteLength(raw) > 2 * 1024 * 1024)
                    throw new ConflictException('Export chunk bound');
                await c.query('INSERT INTO privacy_export_chunks(export_id,sequence,category,item_count,sha256,encrypted_payload) VALUES($1,$2,$3,$4,$5,$6)', [id, sequence, category, rows.length, sha(raw), encrypt(raw, 'EXPORT:v2:' + id + ':' + sequence)]);
            }
            await c.query('UPDATE privacy_export_jobs SET category=category+$2,cursor_id=$3,item_count=item_count+$4 WHERE id=$1', [id, rows.length < batch ? 1 : 0, rows.length < batch ? null : rows.at(-1)!.id, rows.length]);
            return true;
        });
    }
    private async owner(p: Principal, id: string) {
        uuid(id); const j = (await this.db.query("SELECT j.* FROM privacy_export_jobs j JOIN users u ON u.id=j.user_id JOIN sessions s ON s.user_id=u.id WHERE j.id=$1 AND j.user_id=$2 AND s.id=$3 AND s.revoked_at IS NULL AND s.expires_at>now() AND u.status='ACTIVE' AND u.privacy_state='ACTIVE'", [id, p.userId, p.sessionId])).rows[0]; if (!j)
        throw new NotFoundException('Export unavailable'); if (j.expires_at <= new Date() || j.state === 'EXPIRED')
        return { ...j, state: 'EXPIRED', manifest: null }; return j; }
    async result(p: Principal, id: string) { const legacy = (await this.db.query('SELECT state,expires_at FROM privacy_exports WHERE id=$1 AND user_id=$2', [id, p.userId])).rows[0]; if (!legacy)
        throw new NotFoundException(); const j = (await this.db.query('SELECT id FROM privacy_export_jobs WHERE id=$1 AND user_id=$2', [id, p.userId])).rows[0]; if (!j)
        return { state: legacy.expires_at <= new Date() ? 'EXPIRED' : legacy.state }; const job = await this.owner(p, id); if (job.state !== 'READY')
        return { state: job.state }; const chunks = (await this.db.query('SELECT * FROM privacy_export_chunks WHERE export_id=$1 ORDER BY sequence LIMIT 20', [id])).rows; const data: Record<string, any> = { version: 2, rawMediaIncluded: false, partial: Number(job.item_count) > lifecyclePolicy().exportBatch, manifest: job.manifest }; let budget = lifecyclePolicy().exportBatch; for (const chunk of chunks) {
        if (budget <= 0)
            break;
        const text = decrypt(chunk.encrypted_payload, 'EXPORT:v2:' + id + ':' + chunk.sequence);
        if (sha(text) !== chunk.sha256)
            throw new ConflictException('Export integrity unavailable');
        const records = text.trim().split('\n').filter(Boolean).map(v => JSON.parse(v));
        data[chunk.category] = records.slice(0, budget);
        budget -= records.length;
    } return { state: 'READY', manifest: job.manifest, data }; }
    async authorize(p: Principal, id: string, sequence: number) { const job = await this.owner(p, id); if (job.state !== 'READY' || !Number.isInteger(sequence) || sequence < 0 || sequence >= 10000)
        throw new ForbiddenException('Export unavailable'); const r = (await this.db.query('SELECT sha256,item_count FROM privacy_export_chunks WHERE export_id=$1 AND sequence=$2', [id, sequence])).rows[0]; if (!r)
        throw new NotFoundException(); const expires = Math.min(Date.now() + 60000, new Date(job.expires_at).getTime()), payload = Buffer.from(JSON.stringify([p.userId, id, sequence, expires, r.sha256])).toString('base64url'), mac = createHmac('sha256', key()).update('EXPORT_CAP:' + payload).digest('base64url'); return { capability: payload + '.' + mac, expiresAt: new Date(expires).toISOString(), sha256: r.sha256, itemCount: r.item_count, sequence }; }
    async chunk(p: Principal, id: string, sequence: number, capability: string) { const job = await this.owner(p, id); if (job.state !== 'READY' || typeof capability !== 'string' || capability.length > 512)
        throw new ForbiddenException(); const parts = capability.split('.'); if (parts.length !== 2)
        throw new ForbiddenException(); const expected = createHmac('sha256', key()).update('EXPORT_CAP:' + parts[0]).digest(), given = Buffer.from(parts[1]!, 'base64url'); if (given.length !== expected.length || !timingSafeEqual(given, expected))
        throw new ForbiddenException(); let b: any; try {
        b = JSON.parse(Buffer.from(parts[0]!, 'base64url').toString());
    }
    catch {
        throw new ForbiddenException();
    } if (b[0] !== p.userId || b[1] !== id || b[2] !== sequence || !Number.isSafeInteger(b[3]) || b[3] < Date.now() || b[3] > Date.now() + 61000)
        throw new ForbiddenException(); const r = (await this.db.query('SELECT * FROM privacy_export_chunks WHERE export_id=$1 AND sequence=$2', [id, sequence])).rows[0]; if (!r || b[4] !== r.sha256)
        throw new ForbiddenException(); const text = decrypt(r.encrypted_payload, 'EXPORT:v2:' + id + ':' + sequence); if (sha(text) !== r.sha256)
        throw new ConflictException('Export integrity unavailable'); return { schemaVersion: 2, category: r.category, sequence, sha256: r.sha256, ndjson: text }; }
}
