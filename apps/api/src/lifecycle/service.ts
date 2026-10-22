import { sealMail } from '../hardening/email';
import { Inject, Injectable, UnauthorizedException, ForbiddenException, ConflictException, BadRequestException, NotFoundException } from '@nestjs/common';
import { randomUUID, randomBytes } from 'node:crypto';
import type { PoolClient } from 'pg';
import { DatabaseService } from '../database.service';
import { PasswordService } from '../auth/password.service';
import type { Principal } from '../auth/auth.service';
import { ObjectStorageProvider } from '../uploads/storage';
import { BillingProvider } from '../billing/provider';
import { DurableJobs, type DurableJob } from '../hardening/jobs';
import { LifecycleLedger, canonicalTombstone, type Tombstone, type ArchivedObject } from './ledger';
import { body, lifecyclePolicy, sha, identityHMAC } from './policy';
import { AdminService, type AdminPrincipal } from '../admin/service';
import { uuid } from '../auth/input';
@Injectable()
export class LifecycleService {
    constructor(
    @Inject(DatabaseService)
    private db: DatabaseService,
    @Inject(PasswordService)
    private passwords: PasswordService,
    @Inject(ObjectStorageProvider)
    private storage: ObjectStorageProvider,
    @Inject(BillingProvider)
    private billing: BillingProvider,
    @Inject(DurableJobs)
    private jobs: DurableJobs,
    @Inject(LifecycleLedger)
    private ledger: LifecycleLedger,
    @Inject(AdminService)
    private admin: AdminService) { }
    private async event(c: PoolClient, user: string, request: string | null, event: string, item: string | null = null, attempt: number | null = null, actor: string | null = null) { await c.query('INSERT INTO deletion_events(id,user_id,request_id,event,item_id,attempt,actor_id) VALUES($1,$2,$3,$4,$5,$6,$7)', [randomUUID(), user, request, event, item, attempt, actor]); await c.query("INSERT INTO security_audit(id,actor_type,actor_id,action,target_type,target_id,correlation_id,outcome) VALUES($1,$2,$3,$4,'lifecycle',$5,$1,'RECORDED')", [randomUUID(), actor ? 'STAFF' : 'ACCOUNT', actor ?? user, event, request ?? user]); }
    private async notify(c: PoolClient, user: string, request: string, event: 'REQUESTED' | 'CANCELLED' | 'PARTIAL' | 'COMPLETED') { if ((await c.query('SELECT email_id FROM lifecycle_notifications WHERE request_id=$1 AND event=$2', [request, event])).rowCount)
        return; const u = (await c.query('SELECT email FROM users WHERE id=$1', [user])).rows[0]; if (!u || u.email.endsWith('@deleted.invalid'))
        return; const id = randomUUID(), payload = sealMail({ to: u.email, kind: 'deletion', token: '', lifecycleEvent: event }, id); await c.query("INSERT INTO durable_email(id,user_id,kind,encrypted_payload) VALUES($1,$2,'deletion',$3)", [id, user, payload]); await c.query('INSERT INTO lifecycle_notifications(request_id,event,email_id) VALUES($1,$2,$3)', [request, event, id]); await this.jobs.enqueue('EMAIL', id, { emailId: id }, c); }
    private async lock(c: PoolClient, user: string) { const u = (await c.query('SELECT * FROM users WHERE id=$1 FOR UPDATE', [user])).rows[0]; if (!u)
        throw new NotFoundException(); return u; }
    private async state(c: PoolClient, user: string, state: string) { await c.query('INSERT INTO account_lifecycle(user_id,state) VALUES($1,$2) ON CONFLICT(user_id) DO UPDATE SET state=$2,updated_at=now(),version=account_lifecycle.version+1', [user, state]); }
    private async held(c: PoolClient, user: string) { return !!(await c.query('SELECT id FROM data_holds WHERE user_id=$1 AND released_at IS NULL LIMIT 1', [user])).rowCount; }
    private async reauth(user: string, password: unknown) { if (typeof password !== 'string' || password.length > 4096)
        throw new UnauthorizedException('Reauthentication required'); const u = (await this.db.query('SELECT * FROM users WHERE id=$1', [user])).rows[0]; if (!u || u.privacy_state === 'DELETED' || !await this.passwords.verify(u.password_hash, password))
        throw new UnauthorizedException('Reauthentication required'); return u; }
    async request(p: Principal, value: unknown) { if (process.env.ACCOUNT_DELETION_ENABLED !== 'true' || process.env.NODE_ENV === 'production' && process.env.PRIVACY_RETENTION_APPROVED !== 'true')
        throw new ForbiddenException('Deletion policy pending'); let b: Record<string, any>; try {
        b = body(value, ['password', 'confirmation', 'idempotencyKey']);
    }
    catch {
        throw new BadRequestException();
    } if (b.confirmation !== 'DELETE MY ACCOUNT')
        throw new BadRequestException('Explicit confirmation required'); const key = b.idempotencyKey === undefined ? null : uuid(b.idempotencyKey), verifiedAt = Date.now(), verified = await this.reauth(p.userId, b.password), id = randomUUID(), token = randomBytes(32).toString('base64url'), policy = lifecyclePolicy(); return this.db.transaction(async (c) => { const u = await this.lock(c, p.userId); if (Date.now() - verifiedAt > 300000 || u.password_hash !== verified.password_hash)
        throw new UnauthorizedException(); const prior = (await c.query("SELECT * FROM deletion_requests WHERE user_id=$1 AND (state IN('COOLDOWN','IN_PROGRESS','FAILED_REVIEW') OR idempotency_key=$2) ORDER BY created_at DESC LIMIT 1", [p.userId, key])).rows[0]; if (prior)
        return { requestId: prior.id, state: prior.state, notBefore: prior.not_before, cancellationToken: null }; if (u.status !== 'ACTIVE' || u.privacy_state !== 'ACTIVE' || !(await c.query('SELECT id FROM sessions WHERE id=$1 AND user_id=$2 AND revoked_at IS NULL AND expires_at>now()', [p.sessionId, p.userId])).rowCount)
        throw new UnauthorizedException(); const r = (await c.query("INSERT INTO deletion_requests(id,user_id,state,cancel_hash,not_before,requested_session_id,idempotency_key,reauthenticated_at) VALUES($1,$2,'COOLDOWN',$3,now()+$4*interval '1 second',$5,$6,now()) RETURNING not_before", [id, p.userId, sha(token), policy.cooldown, p.sessionId, key])).rows[0]; await c.query("UPDATE users SET status='DISABLED',privacy_state='DELETION_COOLDOWN',beta_state='EXITED_BETA' WHERE id=$1", [p.userId]); await c.query('UPDATE sessions SET revoked_at=COALESCE(revoked_at,now()) WHERE user_id=$1', [p.userId]); // Provider shutdown survives cancellation of the separate deletion workflow.
        await c.query("INSERT INTO billing_provider_jobs(id,user_id,subscription_code) SELECT $2,user_id,provider_subscription_id FROM subscriptions WHERE user_id=$1 AND provider_subscription_id IS NOT NULL ON CONFLICT DO NOTHING", [p.userId, randomUUID()]);
        await c.query("UPDATE subscriptions SET cancel_at_period_end=true,status=CASE WHEN current_period_end>now() THEN 'CANCEL_AT_PERIOD_END' ELSE 'CANCELED' END WHERE user_id=$1", [p.userId]); await c.query("UPDATE billing_checkouts SET status='FAILED' WHERE user_id=$1 AND status IN('PENDING','READY')", [p.userId]); await this.state(c, p.userId, 'DELETION_COOLDOWN'); await this.event(c, p.userId, id, 'DELETION_REQUESTED'); await this.notify(c, p.userId, id, 'REQUESTED'); await this.jobs.enqueue('ACCOUNT_DELETE', id, { userId: p.userId, requestId: id }, c); return { requestId: id, state: 'COOLDOWN', notBefore: r.not_before, cancellationToken: token }; }); }
    async capability(value: unknown, cancel: boolean) { let b: Record<string, any>; try {
        b = body(value, ['requestId', 'cancellationToken', 'password', 'confirmation']);
    }
    catch {
        throw new UnauthorizedException();
    } const id = uuid(b.requestId); if (typeof b.cancellationToken !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(b.cancellationToken))
        throw new UnauthorizedException(); const hint = (await this.db.query("SELECT user_id FROM deletion_requests WHERE id=$1 AND cancel_hash=$2 AND created_at>now()-interval '30 days'", [id, sha(b.cancellationToken)])).rows[0]; if (!hint)
        throw new UnauthorizedException('Request unavailable'); if (cancel && b.password !== undefined)
        await this.reauth(hint.user_id, b.password); return this.db.transaction(async (c) => { await this.lock(c, hint.user_id); const r = (await c.query('SELECT * FROM deletion_requests WHERE id=$1 AND user_id=$2 AND cancel_hash=$3 FOR UPDATE', [id, hint.user_id, sha(b.cancellationToken)])).rows[0]; if (!r)
        throw new UnauthorizedException(); if (!cancel)
        return this.safe(r, (await c.query('SELECT state FROM account_lifecycle WHERE user_id=$1', [r.user_id])).rows[0]?.state); if (r.state !== 'COOLDOWN' || r.execution_started_at || new Date(r.not_before) <= new Date())
        throw new ConflictException('Cancellation window closed'); if (await this.held(c, r.user_id))
        throw new ConflictException('Account requires support review'); await c.query("UPDATE deletion_requests SET state='CANCELLED',cancel_hash=NULL,finished_at=now() WHERE id=$1", [id]); await c.query("UPDATE users SET status='ACTIVE',privacy_state='ACTIVE' WHERE id=$1", [r.user_id]); await c.query("UPDATE durable_jobs SET state='SUCCEEDED',finished_at=now(),lease_id=NULL,lease_until=NULL WHERE kind='ACCOUNT_DELETE' AND payload->>'requestId'=$1 AND state IN('PENDING','RUNNING')", [id]); await this.state(c, r.user_id, 'ACTIVE'); await this.event(c, r.user_id, id, 'DELETION_CANCELLED'); await this.notify(c, r.user_id, id, 'CANCELLED'); return { state: 'CANCELLED', message: 'Sign in again. Renewal remains cancelled.' }; }); }
    private safe(r: any,lifecycle?:string) { const publicState=lifecycle&&['LEGAL_HOLD','SECURITY_HOLD'].includes(lifecycle)?'PAUSED':lifecycle&&['RECOVERY_REVIEW','DELETION_PARTIAL'].includes(lifecycle)?'REQUIRES_SUPPORT':r.state==='FAILED_REVIEW'?'REQUIRES_SUPPORT':r.state;return { requestId: r.id, state: publicState, notBefore: r.not_before, startedAt: r.execution_started_at, completedAt: r.finished_at }; }
    async status(p: Principal) { const r = (await this.db.query('SELECT * FROM deletion_requests WHERE user_id=$1 ORDER BY created_at DESC LIMIT 1', [p.userId])).rows[0]; return r ? this.safe(r, (await this.db.query('SELECT state FROM account_lifecycle WHERE user_id=$1', [p.userId])).rows[0]?.state) : { state: 'NONE' }; }
    private async execution(c: PoolClient, user: string, id: string, job?: DurableJob) { if (!lifecyclePolicy().execution)
        throw new ConflictException('Destructive execution disabled'); await this.lock(c, user); if (await this.held(c, user))
        throw new ConflictException('Deletion held'); const r = (await c.query("SELECT * FROM deletion_requests WHERE id=$1 AND user_id=$2 AND state IN('COOLDOWN','IN_PROGRESS','FAILED_REVIEW') FOR UPDATE", [id, user])).rows[0]; if (!r || new Date(r.not_before) > new Date())
        throw new ConflictException('Deletion not due'); if (job && !(await c.query("SELECT id FROM durable_jobs WHERE id=$1 AND lease_id=$2 AND state='RUNNING' AND lease_until>now() FOR SHARE", [job.id, job.lease_id])).rowCount)
        throw new ConflictException('Worker lease lost'); return r; }
    async preview(user: string, id: string) { const r = (await this.db.query('SELECT state,not_before FROM deletion_requests WHERE id=$1 AND user_id=$2', [id, user])).rows[0]; if (!r)
        throw new NotFoundException(); const totals = (await this.db.query('SELECT count(*)::int count,COALESCE(sum(expected_size_bytes),0)::text bytes FROM assets WHERE user_id=$1', [user])).rows[0]; const holds = (await this.db.query('SELECT count(*)::int count FROM data_holds WHERE user_id=$1 AND released_at IS NULL', [user])).rows[0]; const review = (await this.db.query("SELECT count(*)::int count FROM account_deletion_manifest_items WHERE request_id=$1 AND state='REVIEW'", [id])).rows[0]; return { dryRun: true, accountState: r.state, candidateAssets: totals!.count, estimatedBytes: Number(totals!.bytes), holds: holds!.count, ambiguousItems: review!.count, executionEnabled: lifecyclePolicy().execution }; }
    async run(user: string, id: string, job?: DurableJob) {
        const req = (await this.db.query('SELECT * FROM deletion_requests WHERE id=$1 AND user_id=$2', [id, user])).rows[0];
        if (!req || ['CANCELLED', 'DELETED'].includes(req.state))
            return;
        try {
            if (!req.billing_cancelled) {
                await this.db.transaction(async (c) => { await this.lock(c, user); if (job && !(await c.query("SELECT id FROM durable_jobs WHERE id=$1 AND lease_id=$2 AND state='RUNNING' AND lease_until>now()", [job.id, job.lease_id])).rowCount)
                    throw new ConflictException(); await this.event(c, user, id, 'SUBSCRIPTION_SHUTDOWN_INTENT'); });
                const sub = (await this.db.query('SELECT provider_subscription_id FROM subscriptions WHERE user_id=$1', [user])).rows[0];
                if (sub?.provider_subscription_id)
                    await this.billing.cancelSubscription(sub.provider_subscription_id);
                await this.db.transaction(async (c) => { await this.lock(c, user); await c.query('UPDATE deletion_requests SET billing_cancelled=true WHERE id=$1 AND user_id=$2', [id, user]); await this.event(c, user, id, 'SUBSCRIPTION_SHUTDOWN_CONFIRMED'); });
            }
            if (!lifecyclePolicy().execution || new Date(req.not_before) > new Date() || await this.db.transaction(c => this.held(c, user)))
                return;
            await this.inventory(user, id, job);
            const manifest = (await this.db.query('SELECT * FROM account_deletion_manifest WHERE request_id=$1 AND user_id=$2', [id, user])).rows[0];
            if (!manifest || manifest.state === 'BUILDING' || manifest.state === 'REVIEW')
                return;
            await this.archiveInventory(user, id, manifest.digest, job);
            await this.executeItems(user, id, job);
            await this.finish(user, id, job);
        }
        catch {
            await this.db.transaction(async (c) => { await this.lock(c, user); if ((await c.query("SELECT id FROM deletion_requests WHERE id=$1 AND state NOT IN('CANCELLED','DELETED')", [id])).rowCount) {
                const hold=(await c.query("SELECT kind FROM data_holds WHERE user_id=$1 AND released_at IS NULL ORDER BY kind LIMIT 1",[user])).rows[0];await this.state(c,user,hold?.kind??'DELETION_PARTIAL');
                await this.event(c, user, id, 'DELETION_PARTIAL_FAILURE');
                await this.notify(c, user, id, 'PARTIAL');
            } });
            throw new Error('Lifecycle requires retry');
        }
    }
    private async inventory(user: string, id: string, job?: DurableJob) {
        const batch = lifecyclePolicy().batch;
        const m = await this.db.transaction(async (c) => { await this.execution(c, user, id, job); await c.query('INSERT INTO account_deletion_manifest(request_id,user_id) VALUES($1,$2) ON CONFLICT DO NOTHING', [id, user]); return (await c.query('SELECT * FROM account_deletion_manifest WHERE request_id=$1 FOR UPDATE', [id])).rows[0]; });
        if (m.state !== 'BUILDING')
            return;
        const assets = (await this.db.query('SELECT * FROM assets WHERE user_id=$1 AND ($2::uuid IS NULL OR id>$2) ORDER BY id LIMIT $3', [user, m.cursor_id, batch])).rows;
        for (const a of assets) {
            this.storage.assertBinding(a.storage_provider, a.storage_binding);
            const uploads = (await this.db.query('SELECT * FROM upload_sessions WHERE asset_id=$1 AND user_id=$2', [a.id, user])).rows;
            if (uploads.some(u => u.verification_lease_until && new Date(u.verification_lease_until) > new Date()))
                throw new ConflictException('Verification pending');
            const known = new Set<string>([a.storage_version_id, ...uploads.map(u => u.completed_version_id)].filter(v => v && v !== 'null'));
            const visible = await this.storage.versionsForDeletion(a.storage_object_key);
            if (visible.length > 1000)
                throw new ConflictException('Version inventory bound');
            const resource = (await this.db.query('SELECT id FROM media_manifest_resources WHERE asset_id=$1 AND user_id=$2', [a.id, user])).rows[0]?.id ?? null;
            const items = [...known].sort().map(version => ({ kind: 'OBJECT', version }));
            for (const u of uploads)
                if (u.multipart_upload_id && !u.completed_version_id)
                    items.push({ kind: 'MULTIPART', version: u.multipart_upload_id });
            for (const version of visible)
                if (!known.has(version))
                    items.push({ kind: 'REVIEW', version });
            await this.db.transaction(async (c) => { await this.execution(c, user, id, job); const current = (await c.query('SELECT * FROM account_deletion_manifest WHERE request_id=$1 FOR UPDATE', [id])).rows[0]; if (current.cursor_id && current.cursor_id >= a.id)
                return; for (const item of items)
                await c.query('INSERT INTO account_deletion_manifest_items(id,request_id,user_id,asset_id,resource_id,kind,provider,binding,object_key,provider_version_id,state) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) ON CONFLICT DO NOTHING', [randomUUID(), id, user, a.id, resource, item.kind, a.storage_provider, a.storage_binding, a.storage_object_key, item.version, item.kind === 'REVIEW' ? 'REVIEW' : 'PENDING']); const digest = sha(current.digest + JSON.stringify([a.id, resource, a.storage_provider, a.storage_binding, items])); await c.query('UPDATE account_deletion_manifest SET cursor_id=$2,asset_count=asset_count+1,object_count=object_count+$3,expected_bytes=expected_bytes+$4,digest=$5 WHERE request_id=$1', [id, a.id, items.length, a.expected_size_bytes, digest]); });
        }
        if (assets.length < batch)
            await this.db.transaction(async (c) => { await this.execution(c, user, id, job); const review = !!(await c.query("SELECT id FROM account_deletion_manifest_items WHERE request_id=$1 AND state='REVIEW' LIMIT 1", [id])).rowCount; await c.query("UPDATE account_deletion_manifest SET state=$2,finalized_at=CASE WHEN $2='FINALIZED' THEN now() ELSE NULL END WHERE request_id=$1 AND state='BUILDING'", [id, review ? 'REVIEW' : 'FINALIZED']); await this.event(c, user, id, review ? 'MANIFEST_REQUIRES_REVIEW' : 'MANIFEST_FINALIZED'); if (review)
                await this.state(c, user, 'RECOVERY_REVIEW'); });
    }
    private async archiveInventory(user: string, id: string, digest: string, job?: DurableJob) { const m = (await this.db.query('SELECT archive_ready FROM account_deletion_manifest WHERE request_id=$1', [id])).rows[0]; if (m?.archive_ready)
        return; const db = this.db; async function* pages() { let cursor: string | null = null; while (true) {
        const rows: any[] = (await db.query("SELECT * FROM account_deletion_manifest_items WHERE request_id=$1 AND user_id=$2 AND kind IN('OBJECT','MULTIPART') AND ($3::uuid IS NULL OR id>$3) ORDER BY id LIMIT 100", [id, user, cursor])).rows;
        if (!rows.length)
            return;
        yield rows.map(r => ({ assetId: r.asset_id, kind: r.kind, provider: r.provider, binding: r.binding, objectKey: r.object_key, version: r.provider_version_id })) as ArchivedObject[];
        cursor = rows.at(-1)!.id;
    } } await this.ledger.publishInventory(user, id, digest, pages()); await this.db.transaction(async (c) => { await this.execution(c, user, id, job); await c.query("UPDATE account_deletion_manifest SET archive_ready=true WHERE request_id=$1 AND user_id=$2 AND digest=$3 AND state IN('FINALIZED','EXECUTING')", [id, user, digest]); await this.event(c, user, id, 'INDEPENDENT_INVENTORY_ARCHIVED'); }); }
    private async executeItems(user: string, id: string, job?: DurableJob) {
        await this.db.transaction(async (c) => { await this.execution(c, user, id, job); const m = (await c.query("SELECT request_id FROM account_deletion_manifest WHERE request_id=$1 AND state IN('FINALIZED','EXECUTING') AND archive_ready FOR UPDATE", [id])).rows[0]; if (!m)
            throw new ConflictException(); await c.query("UPDATE account_deletion_manifest SET state='EXECUTING' WHERE request_id=$1", [id]); await c.query("UPDATE deletion_requests SET state='IN_PROGRESS',execution_started_at=COALESCE(execution_started_at,now()) WHERE id=$1", [id]); await c.query("UPDATE users SET privacy_state='DELETION_IN_PROGRESS' WHERE id=$1", [user]); await this.state(c, user, 'DELETION_IN_PROGRESS'); });
        for (let n = 0; n < lifecyclePolicy().batch; n++) {
            const item = await this.db.transaction(async (c) => { await this.execution(c, user, id, job); const r = (await c.query("SELECT * FROM account_deletion_manifest_items WHERE request_id=$1 AND user_id=$2 AND (state='PENDING' OR state='ATTEMPTING' AND lease_until<=now()) ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED", [id, user])).rows[0]; if (!r)
                return null; if (r.attempts >= lifecyclePolicy().retryLimit) {
                await c.query("UPDATE account_deletion_manifest_items SET state='REVIEW',last_error_code='RETRY_THRESHOLD' WHERE id=$1", [r.id]);
                await this.state(c, user, 'DELETION_PARTIAL');
                return null;
            } const lease = randomUUID(); await c.query("UPDATE account_deletion_manifest_items SET state='ATTEMPTING',attempts=attempts+1,lease_id=$2,lease_until=now()+interval '2 minutes' WHERE id=$1", [r.id, lease]); await this.event(c, user, id, 'OBJECT_DELETE_INTENT', r.id, r.attempts + 1); return { ...r, lease_id: lease }; });
            if (!item)
                break;
            try {
                await this.db.transaction(async (c) => { await this.execution(c, user, id, job); const a = (await c.query('SELECT storage_object_key,storage_provider,storage_binding FROM assets WHERE id=$1 AND user_id=$2 FOR SHARE', [item.asset_id, user])).rows[0]; if (!a || a.storage_object_key !== item.object_key || a.storage_provider !== item.provider || a.storage_binding !== item.binding)
                    throw new ConflictException('Object ownership changed'); if (!(await c.query("SELECT id FROM account_deletion_manifest_items WHERE id=$1 AND lease_id=$2 AND state='ATTEMPTING' AND lease_until>now() FOR UPDATE", [item.id, item.lease_id])).rowCount)
                    throw new ConflictException('Item lease lost'); this.storage.assertBinding(item.provider, item.binding); if (item.kind === 'MULTIPART') {
                    try {
                        await this.storage.abortMultipart(item.object_key, item.provider_version_id);
                    }
                    catch (e) {
                        if ((e as any).name !== 'NoSuchUpload')
                            throw e;
                    }
                }
                else if (item.kind === 'OBJECT') {
                    const visible = await this.storage.versionsForDeletion(item.object_key);
                    if (visible.includes(item.provider_version_id))
                        await this.storage.deleteObject(item.object_key, item.provider_version_id);
                    if ((await this.storage.versionsForDeletion(item.object_key)).includes(item.provider_version_id))
                        throw new ConflictException('Provider deletion unconfirmed');
                }
                else
                    throw new ConflictException(); if (!(await c.query("UPDATE account_deletion_manifest_items SET state='DELETED',deleted_at=now(),lease_until=NULL WHERE id=$1 AND lease_id=$2 AND state='ATTEMPTING' RETURNING id", [item.id, item.lease_id])).rowCount)
                    throw new ConflictException('Item lease lost'); await this.event(c, user, id, 'OBJECT_DELETE_CONFIRMED', item.id, item.attempts + 1); });
            }
            catch {
                await this.db.query("UPDATE account_deletion_manifest_items SET state='PENDING',lease_until=NULL,last_error_code='PROVIDER_DELETE_RETRY' WHERE id=$1 AND lease_id=$2 AND state='ATTEMPTING'", [item.id, item.lease_id]);
                throw new Error('Provider deletion incomplete');
            }
        }
    }
    private async finish(user: string, id: string, job?: DurableJob) {
        const ready = await this.db.transaction(async (c) => { const r = await this.execution(c, user, id, job); const m = (await c.query('SELECT * FROM account_deletion_manifest WHERE request_id=$1 FOR UPDATE', [id])).rows[0]; if (!r.billing_cancelled || m.state !== 'EXECUTING' || (await c.query("SELECT id FROM account_deletion_manifest_items WHERE request_id=$1 AND state NOT IN('DELETED','RETAINED') LIMIT 1", [id])).rowCount)
            return null; return m; });
        if (!ready)
            return;
        const page = (await this.db.query('SELECT * FROM assets WHERE user_id=$1 AND ($2::uuid IS NULL OR id>$2) ORDER BY id LIMIT $3', [user, ready.final_cursor_id, lifecyclePolicy().batch])).rows;
        for (const a of page) {
            this.storage.assertBinding(a.storage_provider, a.storage_binding);
            const visible = await this.storage.versionsForDeletion(a.storage_object_key);
            if (visible.length) {
                await this.db.transaction(async (c) => { await this.execution(c, user, id, job); let review = false; for (const version of visible) {
                    const known = (await c.query("SELECT id FROM account_deletion_manifest_items WHERE request_id=$1 AND asset_id=$2 AND kind='OBJECT' AND provider_version_id=$3 AND object_key=$4 AND provider=$5 AND binding IS NOT DISTINCT FROM $6 FOR UPDATE", [id, a.id, version, a.storage_object_key, a.storage_provider, a.storage_binding])).rows[0];
                    if (known) {
                        await c.query("UPDATE account_deletion_manifest_items SET state='PENDING',deleted_at=NULL,lease_id=NULL,lease_until=NULL WHERE id=$1", [known.id]);
                        await this.event(c, user, id, 'KNOWN_OBJECT_REAPPEARED', known.id);
                    }
                    else {
                        review = true;
                        await c.query("INSERT INTO account_deletion_manifest_items(id,request_id,user_id,asset_id,kind,provider,binding,object_key,provider_version_id,state) VALUES($1,$2,$3,$4,'REVIEW',$5,$6,$7,$8,'REVIEW') ON CONFLICT DO NOTHING", [randomUUID(), id, user, a.id, a.storage_provider, a.storage_binding, a.storage_object_key, version]);
                    }
                } await c.query("UPDATE account_deletion_manifest SET state=$2,final_cursor_id=NULL WHERE request_id=$1", [id, review ? 'REVIEW' : 'EXECUTING']); await this.state(c, user, review ? 'RECOVERY_REVIEW' : 'DELETION_PARTIAL'); await this.event(c, user, id, review ? 'OBJECT_REAPPEARANCE_REVIEW' : 'EXACT_REDELETION_QUEUED'); });
                return;
            }
            await this.db.query('UPDATE account_deletion_manifest SET final_cursor_id=$2 WHERE request_id=$1 AND user_id=$3', [id, a.id, user]);
        }
        if (page.length === lifecyclePolicy().batch)
            return;
        const t = await this.db.transaction(async (c) => { await this.execution(c, user, id, job); const u = await this.lock(c, user); const m = (await c.query('UPDATE account_deletion_manifest SET completed_at=COALESCE(completed_at,now()) WHERE request_id=$1 RETURNING *', [id])).rows[0]; return { userId: user, deletionId: id, completedAt: new Date(m.completed_at).toISOString(), manifestDigest: m.digest, lifecycleVersion: 2 as const, identityHmac: process.env.LIFECYCLE_IDENTITY_HMAC_KEY ? identityHMAC(u.email_normalized, process.env.LIFECYCLE_IDENTITY_HMAC_KEY) : null, identityExpiresAt: null }; });
        const archive = await this.ledger.publish(t);
        await this.db.transaction(async (c) => { const r = await this.execution(c, user, id, job); if (!r.billing_cancelled)
            throw new ConflictException(); await this.notify(c, user, id, 'COMPLETED'); await this.restorePII(c,user); await c.query('INSERT INTO account_deletion_tombstones(user_id,deletion_id,completed_at,manifest_digest,lifecycle_version,identity_hmac,identity_expires_at,archive_digest) VALUES($1,$2,$3,$4,2,$5,$6,$7) ON CONFLICT DO NOTHING', [user, id, t.completedAt, t.manifestDigest, t.identityHmac, t.identityExpiresAt, archive]); await this.state(c, user, 'DELETED'); await c.query("UPDATE deletion_requests SET state='DELETED',finished_at=now() WHERE id=$1", [id]); await c.query("UPDATE account_deletion_manifest SET state='COMPLETE' WHERE request_id=$1", [id]); await this.event(c, user, id, 'DATABASE_PII_PROCESSED'); await this.event(c, user, id, 'DELETION_COMPLETED'); });
    }
    private async adoptLegacyDeletions(){const rows=(await this.db.query("SELECT r.id,r.user_id,r.finished_at,r.manifest_complete FROM deletion_requests r WHERE r.state='DELETED' AND NOT EXISTS(SELECT 1 FROM account_deletion_tombstones t WHERE t.user_id=r.user_id) ORDER BY r.id LIMIT 100")).rows;for(const r of rows){const existing=await this.ledger.lookup(r.id);if(existing){if(existing.userId!==r.user_id)throw new ConflictException('Legacy archive identity mismatch');continue;}if(!r.finished_at||!r.manifest_complete)throw new ConflictException('Legacy deletion evidence requires review');const old=(await this.db.query("SELECT count(*)::int total,count(*) FILTER(WHERE o.state='DELETED' AND a.user_id=$2)::int proven FROM deletion_objects o JOIN assets a ON a.id=o.asset_id WHERE o.request_id=$1",[r.id,r.user_id])).rows[0];if(old!.total!==old!.proven)throw new ConflictException('Legacy deletion inventory requires review');const digest=sha('LEGACY_COMPLETED:'+r.id+':'+r.finished_at.toISOString()+':'+old!.total),db=this.db;async function* pages(){let asset:string|null=null,version:string|null=null;while(true){const items:any[]=(await db.query("SELECT o.asset_id,o.version_id,a.storage_provider,a.storage_binding,a.storage_object_key FROM deletion_objects o JOIN assets a ON a.id=o.asset_id WHERE o.request_id=$1 AND a.user_id=$2 AND ($3::uuid IS NULL OR (o.asset_id,o.version_id)>($3,$4)) ORDER BY o.asset_id,o.version_id LIMIT 100",[r.id,r.user_id,asset,version])).rows;if(!items.length)return;yield items.map(o=>({assetId:o.asset_id,kind:'OBJECT' as const,provider:o.storage_provider,binding:o.storage_binding,objectKey:o.storage_object_key,version:o.version_id}));asset=items.at(-1)!.asset_id;version=items.at(-1)!.version_id;}}await this.ledger.publishInventory(r.user_id,r.id,digest,pages());const t:Tombstone={userId:r.user_id,deletionId:r.id,completedAt:r.finished_at.toISOString(),manifestDigest:digest,lifecycleVersion:2,identityHmac:null,identityExpiresAt:null};const archive=await this.ledger.publish(t);await this.db.transaction(async c=>{await c.query('SELECT id FROM users WHERE id=$1 FOR UPDATE',[r.user_id]);await c.query('INSERT INTO account_deletion_tombstones(user_id,deletion_id,completed_at,manifest_digest,lifecycle_version,archive_digest) VALUES($1,$2,$3,$4,2,$5) ON CONFLICT DO NOTHING',[r.user_id,r.id,t.completedAt,digest,archive]);await this.event(c,r.user_id,r.id,'LEGACY_COMPLETION_ARCHIVED');});}if(rows.length===100)throw new ConflictException('Legacy archive adoption requires another bounded startup pass');}
    private async restorePII(c:PoolClient,user:string){await c.query('DELETE FROM saved_thumbnails WHERE user_id=$1',[user]);const u=(await c.query('SELECT email_normalized,lifecycle_pii_version FROM users WHERE id=$1',[user])).rows[0];if(!u||u.lifecycle_pii_version===2)return;const salt=randomBytes(32).toString('hex');await c.query("UPDATE beta_invites SET token_hash=encode(sha256(convert_to($1||id::text,'UTF8')),'hex'),status='REVOKED',email_normalized=$2 WHERE email_normalized=$3",[salt,'deleted-'+user+'@deleted.invalid',u.email_normalized]);await c.query("UPDATE users SET email=$2,email_normalized=$2,password_hash=$3,status='DISABLED',privacy_state='DELETED',beta_state='EXITED_BETA' WHERE id=$1",[user,'deleted-'+user+'@deleted.invalid','disabled-'+randomUUID()]);await c.query('DELETE FROM email_verification_tokens WHERE user_id=$1',[user]);await c.query('DELETE FROM password_reset_tokens WHERE user_id=$1',[user]);await c.query("UPDATE sessions SET revoked_at=COALESCE(revoked_at,now()),token_hash=encode(sha256(convert_to($2||id::text,'UTF8')),'hex') WHERE user_id=$1",[user,salt]);await c.query("UPDATE devices SET device_identifier='deleted-'||id::text||'-'||$2,display_name='Deleted account',os_version=NULL,app_version=NULL,revoked_at=COALESCE(revoked_at,now()) WHERE user_id=$1",[user,salt]);await c.query("UPDATE beta_feedback SET message='',app_version=NULL WHERE user_id=$1",[user]);await c.query("UPDATE media_manifests SET library_id=NULL,source_token=id,source_fingerprint=encode(sha256(convert_to($2||id::text,'UTF8')),'hex'),creation_time=NULL,modification_time=NULL,pixel_width=0,pixel_height=0,duration_seconds=NULL WHERE user_id=$1",[user,salt]);await c.query('UPDATE assets SET source_library_id=NULL WHERE user_id=$1',[user]);await c.query("UPDATE local_cleanup_proofs SET token_hash=encode(sha256(convert_to($2||id::text,'UTF8')),'hex'),state=CASE WHEN state='CONSUMED' THEN 'CONSUMED' ELSE 'REJECTED' END WHERE user_id=$1",[user,salt]);await c.query('DELETE FROM privacy_export_chunks WHERE export_id IN(SELECT id FROM privacy_export_jobs WHERE user_id=$1)',[user]);await c.query("UPDATE privacy_export_jobs SET state='EXPIRED',manifest=NULL WHERE user_id=$1",[user]);await c.query("UPDATE privacy_exports SET state='EXPIRED',payload=NULL WHERE user_id=$1",[user]);await c.query("UPDATE durable_email SET state='DEAD',encrypted_payload='' WHERE user_id=$1 AND kind<>'deletion'",[user]);await c.query('UPDATE users SET lifecycle_pii_version=2 WHERE id=$1',[user]);}
    async replayTombstones() {
        await this.adoptLegacyDeletions();
        let suppressed = 0, queued = 0;
        for await (const t of this.ledger.entries()) {
            const digest = sha(canonicalTombstone(t));
            await this.db.transaction(async (c) => { const existing = (await c.query('SELECT archive_digest FROM account_deletion_tombstones WHERE user_id=$1', [t.userId])).rows[0]; if (existing && existing.archive_digest !== digest)
                throw new ConflictException('Tombstone archive conflict'); await c.query('SELECT id FROM users WHERE id=$1 FOR UPDATE', [t.userId]); await c.query('INSERT INTO account_deletion_tombstones(user_id,deletion_id,completed_at,manifest_digest,lifecycle_version,identity_hmac,identity_expires_at,archive_digest) VALUES($1,$2,$3,$4,2,$5,$6,$7) ON CONFLICT DO NOTHING', [t.userId, t.deletionId, t.completedAt, t.manifestDigest, t.identityHmac, t.identityExpiresAt, digest]); const u = (await c.query("UPDATE users SET status='DISABLED',privacy_state='DELETED',beta_state='EXITED_BETA' WHERE id=$1 RETURNING id", [t.userId])).rows[0]; if (u) {
                await c.query('UPDATE sessions SET revoked_at=COALESCE(revoked_at,now()) WHERE user_id=$1', [t.userId]);
                await c.query('UPDATE assets SET privacy_deleted_at=COALESCE(privacy_deleted_at,now()) WHERE user_id=$1', [t.userId]);
                await c.query("UPDATE subscriptions SET status='CANCELED',cancel_at_period_end=true WHERE user_id=$1", [t.userId]);
                await c.query('UPDATE upload_sessions SET reservation_released_at=COALESCE(reservation_released_at,now()) WHERE user_id=$1',[t.userId]);await c.query('UPDATE development_entitlements SET protected_bytes=0,reserved_bytes=0 WHERE user_id=$1',[t.userId]);if(!await this.held(c,t.userId))await this.restorePII(c,t.userId);await this.state(c, t.userId, 'DELETED');await c.query("UPDATE deletion_requests SET state='DELETED',finished_at=$3,cancel_hash=NULL WHERE id=$1 AND user_id=$2",[t.deletionId,t.userId,t.completedAt]);await c.query("UPDATE account_deletion_manifest SET state='COMPLETE' WHERE request_id=$1 AND user_id=$2 AND digest=$3",[t.deletionId,t.userId,t.manifestDigest]);
                suppressed++;
            } const prior = (await c.query('SELECT id FROM lifecycle_replays WHERE user_id=$1 AND tombstone_digest=$2 LIMIT 1', [t.userId, digest])).rows[0]; if (!prior) {
                await c.query("INSERT INTO lifecycle_replays(id,user_id,tombstone_digest,state) VALUES($1,$2,$3,'REVIEW')", [randomUUID(), t.userId, digest]);
                await this.event(c, t.userId, null, 'TOMBSTONE_REPLAY_SUPPRESSED');
            } });
            let count = 0;
            for await (const page of this.ledger.inventory(t)) {
                await this.db.transaction(async (c) => { for (const o of page) {
                    await c.query("INSERT INTO lifecycle_redelete_items(id,user_id,deletion_id,asset_id,kind,provider,binding,object_key,provider_version_id) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9) ON CONFLICT(deletion_id,asset_id,kind,provider_version_id) DO UPDATE SET state=CASE WHEN lifecycle_redelete_items.state='DELETED' THEN 'PENDING' ELSE lifecycle_redelete_items.state END", [randomUUID(), t.userId, t.deletionId, o.assetId, o.kind, o.provider, o.binding, o.objectKey, o.version]);
                    count++;
                } });
            }
            await this.db.transaction(async (c) => { await c.query('UPDATE lifecycle_replays SET inventory_verified=true,state=$3 WHERE user_id=$1 AND tombstone_digest=$2', [t.userId, digest, count ? 'REDELETION_QUEUED' : 'SUPPRESSED']); if (count)
                await this.jobs.enqueue('ACCOUNT_REDELETE', t.deletionId + ':' + randomUUID(), { userId: t.userId, requestId: t.deletionId }, c); await this.event(c, t.userId, null, 'REPLAY_INVENTORY_VERIFIED'); });
            queued += count;
        }
        return { suppressed, queued };
    }
    async replayDelete(user: string, deletionId: string, job?: DurableJob) {
        if (!lifecyclePolicy().execution)
            return;
        for (let n = 0; n < lifecyclePolicy().batch; n++) {
            const item = await this.db.transaction(async (c) => { await c.query('SELECT id FROM users WHERE id=$1 FOR UPDATE', [user]); if (await this.held(c, user))
                return null; const r = (await c.query("SELECT i.* FROM lifecycle_redelete_items i WHERE i.user_id=$1 AND i.deletion_id=$2 AND i.state='PENDING' AND EXISTS(SELECT 1 FROM lifecycle_replays r JOIN account_deletion_tombstones t ON t.user_id=r.user_id AND t.archive_digest=r.tombstone_digest WHERE r.user_id=i.user_id AND t.deletion_id=i.deletion_id AND r.inventory_verified) ORDER BY i.id LIMIT 1 FOR UPDATE", [user, deletionId])).rows[0]; if (!r)
                return null; if(job&&!(await c.query("SELECT id FROM durable_jobs WHERE id=$1 AND lease_id=$2 AND state='RUNNING' AND lease_until>now() FOR SHARE",[job.id,job.lease_id])).rowCount)throw new ConflictException('Worker lease lost');await this.restorePII(c,user); if (r.attempts >= lifecyclePolicy().retryLimit) {
                await c.query("UPDATE lifecycle_redelete_items SET state='REVIEW' WHERE id=$1", [r.id]);
                await this.event(c, user, null, 'REPLAY_RETRY_THRESHOLD', r.id);
                return null;
            } await c.query('UPDATE lifecycle_redelete_items SET attempts=attempts+1 WHERE id=$1', [r.id]); await this.event(c, user, null, 'REPLAY_EXACT_DELETE_INTENT', r.id, r.attempts + 1); return r; });
            if (!item)
                break;
            await this.db.transaction(async (c) => { await c.query('SELECT id FROM users WHERE id=$1 FOR UPDATE', [user]); if (await this.held(c, user) || !lifecyclePolicy().execution)
                throw new ConflictException('Replay held'); if (job && !(await c.query("SELECT id FROM durable_jobs WHERE id=$1 AND lease_id=$2 AND state='RUNNING' AND lease_until>now() FOR SHARE", [job.id, job.lease_id])).rowCount)
                throw new ConflictException('Worker lease lost'); const r = (await c.query("SELECT id FROM lifecycle_redelete_items WHERE id=$1 AND state='PENDING' FOR UPDATE", [item.id])).rows[0]; if (!r)
                return; this.storage.assertBinding(item.provider, item.binding); if (item.kind === 'MULTIPART') {
                try {
                    await this.storage.abortMultipart(item.object_key, item.provider_version_id);
                }
                catch (e) {
                    if ((e as any).name !== 'NoSuchUpload')
                        throw e;
                }
            }
            else {
                const visible = await this.storage.versionsForDeletion(item.object_key);
                if (visible.includes(item.provider_version_id))
                    await this.storage.deleteObject(item.object_key, item.provider_version_id);
                const remaining = await this.storage.versionsForDeletion(item.object_key);
                if (remaining.includes(item.provider_version_id))
                    throw new ConflictException('Replay provider mismatch');
                if (remaining.some(v => v !== item.provider_version_id)) {
                    await c.query("UPDATE lifecycle_replays SET state='REVIEW' WHERE user_id=$1", [user]);
                    await this.event(c, user, null, 'REPLAY_UNEXPECTED_VERSION_RETAINED', item.id);
                }
            } await c.query("UPDATE lifecycle_redelete_items SET state='DELETED' WHERE id=$1", [item.id]); await this.event(c, user, null, 'REPLAY_EXACT_DELETE_CONFIRMED', item.id); });
        }
        return { pending: Number((await this.db.query("SELECT count(*) n FROM lifecycle_redelete_items WHERE user_id=$1 AND deletion_id=$2 AND state='PENDING'", [user, deletionId])).rows[0]!.n) };
    }
    async hold(p: AdminPrincipal, user: string, value: unknown) { let b: Record<string, any>; try {
        b = body(value, ['kind', 'reasonCode', 'holdId', 'release', 'idempotencyKey']);
    }
    catch {
        throw new BadRequestException();
    } if (!['LEGAL_REVIEW', 'SECURITY_REVIEW', 'INCIDENT_RESPONSE'].includes(b.reasonCode))
        throw new BadRequestException('Reason code required'); return this.db.transaction(async (c) => { await this.admin.authorize(c, p, 'account', true); const account = await this.lock(c, uuid(user)); if (b.release === true) {
        const id = uuid(b.holdId);
        const r = await c.query('UPDATE data_holds SET released_at=now(),released_by=$3 WHERE id=$1 AND user_id=$2 AND released_at IS NULL RETURNING id', [id, user, p.adminId]);
        if(!r.rowCount){if((await c.query('SELECT id FROM data_holds WHERE id=$1 AND user_id=$2 AND released_at IS NOT NULL',[id,user])).rowCount)return{released:true};throw new ConflictException('Hold unavailable');}
        await this.event(c, user, null, 'HOLD_RELEASED', id, null, p.adminId);
        if (!await this.held(c, user)) {
            const r = (await c.query("SELECT id FROM deletion_requests WHERE user_id=$1 AND state IN('COOLDOWN','IN_PROGRESS','FAILED_REVIEW') ORDER BY created_at DESC LIMIT 1", [user])).rows[0];
            await this.state(c, user, account.privacy_state === 'DELETED' ? 'DELETED' : r ? 'DELETION_PARTIAL' : 'ACTIVE');
            await c.query('SELECT lifecycle_refresh_state($1)', [user]);
        }else{const hold=(await c.query('SELECT kind FROM data_holds WHERE user_id=$1 AND released_at IS NULL ORDER BY kind LIMIT 1',[user])).rows[0];await this.state(c,user,account.privacy_state==='DELETED'?'DELETED':hold!.kind);}
        return { released: true };
    } if (!['LEGAL_HOLD', 'SECURITY_HOLD'].includes(b.kind))
        throw new BadRequestException(); const id = b.idempotencyKey ? uuid(b.idempotencyKey) : randomUUID(); const prior = (await c.query('SELECT user_id,kind,reason_code FROM data_holds WHERE id=$1', [id])).rows[0]; if (prior) {
        if (prior.user_id !== user || prior.kind !== b.kind || prior.reason_code !== b.reasonCode)
            throw new ConflictException('Operation key conflict');
        return { holdId: id, kind: b.kind };
    } await c.query('INSERT INTO data_holds(id,user_id,kind,reason_code,created_by) VALUES($1,$2,$3,$4,$5)', [id, user, b.kind, b.reasonCode, p.adminId]); await this.state(c, user, account.privacy_state === 'DELETED' ? 'DELETED' : b.kind); await this.event(c, user, null, 'HOLD_PLACED', id, null, p.adminId); return { holdId: id, kind: b.kind }; }); }
    async adminStatus(p: AdminPrincipal, user: string) { return this.db.transaction(async (c) => { await this.admin.authorize(c, p, 'users'); const id = uuid(user), u = (await c.query('SELECT id FROM users WHERE id=$1', [id])).rows[0]; if (!u)
        throw new NotFoundException(); return { accountId: id, lifecycle: (await c.query('SELECT state,version,updated_at FROM account_lifecycle WHERE user_id=$1', [id])).rows[0], requests: (await c.query('SELECT id,state,not_before,execution_started_at,finished_at,billing_cancelled FROM deletion_requests WHERE user_id=$1 ORDER BY created_at DESC LIMIT 5', [id])).rows, holds: (await c.query('SELECT id,kind,reason_code,created_at FROM data_holds WHERE user_id=$1 AND released_at IS NULL', [id])).rows, items: (await c.query('SELECT state,count(*)::int count FROM account_deletion_manifest_items WHERE user_id=$1 GROUP BY state', [id])).rows }; }); }
    async retry(p: AdminPrincipal, user: string, value: unknown) { let b: Record<string, any>; try {
        b = body(value, ['requestId', 'reasonCode', 'idempotencyKey']);
    }
    catch {
        throw new BadRequestException();
    } if (b.reasonCode !== 'INCIDENT_RESPONSE')
        throw new BadRequestException('Reason required'); const id = uuid(b.requestId), key = uuid(b.idempotencyKey); return this.db.transaction(async (c) => { await this.admin.authorize(c, p, 'account', true); await this.lock(c, uuid(user)); if (await this.held(c, user))
        throw new ConflictException('Held'); const r = (await c.query("SELECT id,state FROM deletion_requests WHERE id=$1 AND user_id=$2 AND state IN('COOLDOWN','IN_PROGRESS','FAILED_REVIEW') FOR UPDATE", [id, user])).rows[0], m = (await c.query('SELECT state FROM account_deletion_manifest WHERE request_id=$1 AND user_id=$2', [id, user])).rows[0]; if (!r || m?.state === 'REVIEW' || (await c.query("SELECT id FROM account_deletion_manifest_items WHERE request_id=$1 AND kind='REVIEW' LIMIT 1", [id])).rowCount)
        throw new ConflictException('Scope review required'); await c.query("UPDATE account_deletion_manifest_items SET state='PENDING',attempts=0,lease_id=NULL,lease_until=NULL WHERE request_id=$1 AND kind IN('OBJECT','MULTIPART') AND state='REVIEW'", [id]); await c.query("UPDATE deletion_requests SET state=$2 WHERE id=$1", [id, m?.state === 'EXECUTING' ? 'IN_PROGRESS' : 'COOLDOWN']); await this.jobs.enqueue('ACCOUNT_DELETE', id + ':manual:' + key, { userId: user, requestId: id }, c); await this.event(c, user, id, 'MANUAL_SCOPED_RETRY', null, null, p.adminId); return { queued: true, requestId: id }; }); }
    async aggregate(p: AdminPrincipal) { await this.db.transaction(c => this.admin.authorize(c, p, 'overview')); return { states: (await this.db.query('SELECT state,count(*)::int count FROM account_lifecycle GROUP BY state')).rows, items: (await this.db.query('SELECT state,count(*)::int count FROM account_deletion_manifest_items GROUP BY state')).rows, replays: (await this.db.query('SELECT state,count(*)::int count FROM lifecycle_replays GROUP BY state')).rows }; }
}
