import {storageCostEstimate} from '../billing/storage-cost';
import {alertSummary} from './projections';
import {Inject,Injectable} from '@nestjs/common';import {randomUUID} from 'node:crypto';import {DatabaseService} from '../database.service';import {ObjectStorageProvider} from '../uploads/storage';
export type Alert={id:string;code:string;severity:'WARNING'|'CRITICAL';summary:Record<string,number|boolean>};
export abstract class AlertSink{abstract send(event:Alert):Promise<void>;}
export class PendingAlertSink extends AlertSink{async send(){throw new Error('External alert integration pending');}}
export class MemoryAlertSink extends AlertSink{events=new Map<string,Alert>();async send(e:Alert){this.events.set(e.id,e);}}
export const alertThresholds={AUTH_FAILURE_SPIKE:100,ADMIN_AUTH_ANOMALY:10,VERIFICATION_FAILURE_SPIKE:10,BILLING_FAILURE_SPIKE:10,WORKER_BACKLOG:1000,DEAD_JOBS:1,AUDIT_BACKLOG:1000,RECONCILIATION_BACKLOG:100,QUOTA_MISMATCH:1};
@Injectable() export class ObservabilityService{
 constructor(@Inject(DatabaseService)private db:DatabaseService,@Inject(ObjectStorageProvider)private storage:ObjectStorageProvider,@Inject(AlertSink)private sink:AlertSink){}
 async emit(code:string,severity:Alert['severity'],summary:Alert['summary']){summary=alertSummary(summary);const id=randomUUID(),window=String(Math.floor(Date.now()/300000));let event:Alert={id,code,severity,summary};try{const r=(await this.db.query('INSERT INTO alert_events(id,code,severity,window_key,summary) VALUES($1,$2,$3,$4,$5) ON CONFLICT(code,window_key) DO NOTHING RETURNING id',[id,code,severity,window,JSON.stringify(summary)])).rows[0];if(!r)return;event.id=r.id;}catch{if(code!=='DATABASE_UNAVAILABLE')throw new Error('Alert persistence failed');}try{await this.sink.send(event);await this.db.query('UPDATE alert_events SET delivered_at=now() WHERE id=$1',[event.id]);}catch{/* Durable pending event retained; DB-outage delivery also needs independent vendor monitoring. */}}
 async metrics(){return(await this.db.query(`SELECT
 (SELECT count(*)::int FROM deletion_requests WHERE created_at>now()-interval '1 day') AS "deletionRequests",
 (SELECT count(*)::int FROM deletion_requests WHERE state='DELETED') AS "deletionCompletions",
 (SELECT count(*)::int FROM account_lifecycle WHERE state='DELETION_PARTIAL') AS "deletionPartial",
 (SELECT count(*)::int FROM deletion_requests r WHERE r.state IN('COOLDOWN','IN_PROGRESS','FAILED_REVIEW') AND r.not_before<now()-interval '1 day' AND NOT EXISTS(SELECT 1 FROM data_holds h WHERE h.user_id=r.user_id AND h.released_at IS NULL)) AS "deletionStuck",
 (SELECT count(*)::int FROM account_deletion_manifest_items WHERE state='REVIEW' AND last_error_code='RETRY_THRESHOLD') AS "deletionRetryThreshold",
 (SELECT count(*)::int FROM account_deletion_manifest_items WHERE state IN('PENDING','ATTEMPTING')) AS "objectsPendingDeletion",
 (SELECT count(*)::int FROM lifecycle_replays WHERE created_at>now()-interval '5 minutes') AS "tombstoneReplays",
 (SELECT count(*)::int FROM deletion_events WHERE event IN('KNOWN_OBJECT_REAPPEARED','OBJECT_REAPPEARANCE_REVIEW','REPLAY_UNEXPECTED_VERSION_RETAINED') AND created_at>now()-interval '5 minutes') AS "objectReappearance",
 (SELECT count(*)::int FROM billing_audit WHERE action='DELETION_PAYMENT_REVIEW' AND created_at>now()-interval '5 minutes') AS "lateDeletionPayments",
 (SELECT count(*)::int FROM privacy_export_jobs WHERE state='FAILED') AS "exportFailures",
 (SELECT count(*)::int FROM privacy_exports WHERE created_at>now()-interval '1 day') AS "exportRequests",
 (SELECT count(*)::int FROM data_holds WHERE released_at IS NULL) AS "dataHolds",
 (SELECT count(*)::int FROM retention_runs WHERE processed>100) AS "retentionAbnormalVolume",
 (SELECT count(*)::int FROM media_manifests) AS "manifestsCreated",
 (SELECT count(*)::int FROM media_manifest_summary WHERE protection_state='PARTIALLY_PROTECTED') AS "partialManifests",
 (SELECT count(*)::int FROM media_manifest_summary WHERE protection_state='FULLY_PROTECTED') AS "fullyProtectedManifests",
 (SELECT count(*)::int FROM media_manifests WHERE review_required) AS "unknownResourceManifests",
 (SELECT count(*)::int FROM media_manifests WHERE source_changed) AS "sourceChangeInvalidations",
 (SELECT count(*)::int FROM media_manifest_summary WHERE kind='LIVE_PHOTO' AND protection_state IN('INCOMPLETE','SOURCE_CHANGED','UNSUPPORTED')) AS "livePhotoFailures",
 (SELECT count(*)::int FROM media_manifest_summary WHERE kind IN('RAW','RAW_JPEG') AND protection_state IN('INCOMPLETE','SOURCE_CHANGED','UNSUPPORTED')) AS "rawFailures",
 (SELECT count(*)::int FROM restore_events WHERE code='REQUESTED' AND created_at>now()-interval '1 hour') AS "restoreRequests",
 (SELECT count(*)::int FROM restore_events WHERE code='DOWNLOAD_OK' AND created_at>now()-interval '1 hour') AS "restoreDownloads",
 (SELECT count(*)::int FROM restore_events WHERE code='DOWNLOAD_FAILED' AND created_at>now()-interval '1 hour') AS "restoreDownloadFailures",
 (SELECT count(*)::int FROM restore_events WHERE code='CHECKSUM_FAILED' AND created_at>now()-interval '1 hour') AS "restoreChecksumFailures",
 (SELECT count(*)::int FROM restore_events WHERE code='SAVE_FAILED' AND created_at>now()-interval '1 hour') AS "restorePhotoFailures",
 (SELECT count(*)::int FROM restore_events WHERE code='CLEANUP_FAILED' AND created_at>now()-interval '1 hour') AS "restoreCleanupFailures",
 (SELECT count(*)::int FROM restore_events WHERE code='REQUESTED' AND retry_count>0 AND created_at>now()-interval '1 hour') AS "restoreRetries",
 (SELECT COALESCE(avg(duration_ms),0)::float FROM restore_events WHERE code='DOWNLOAD_OK' AND created_at>now()-interval '1 hour') AS "restoreTransferLatencyMs",
 (SELECT count(*)::int FROM restore_events WHERE code='COMPLETED' AND created_at>now()-interval '1 hour') AS "restoreCompletions",
 (SELECT count(*)::int FROM restore_events WHERE code IN('DOWNLOAD_FAILED','CHECKSUM_FAILED','SAVE_FAILED','CLEANUP_FAILED') AND created_at>now()-interval '1 hour') AS "restoreFailures",
 (SELECT COALESCE(avg(duration_ms),0)::float FROM restore_events WHERE code='COMPLETED' AND created_at>now()-interval '1 hour') AS "restoreLatencyMs",
 (SELECT count(*)::int FROM upload_sessions WHERE status IN('QUEUED','UPLOADING','UPLOADED','VERIFYING') AND expires_at>now()) AS "activeUploads",
 (SELECT count(*)::int FROM upload_sessions WHERE expires_at<=now() AND cleanup_completed_at IS NULL AND status<>'PROTECTED') AS "staleUploads",
 (SELECT COALESCE(sum(protected_bytes),0)::text FROM development_entitlements) AS "protectedBytes",
 (SELECT COALESCE(sum(reserved_bytes),0)::text FROM development_entitlements) AS "reservedBytes",
 (SELECT count(*)::int FROM metric_events WHERE code='LOGIN_OK' AND created_at>now()-interval '5 minutes') AS "loginSuccesses",
 (SELECT count(*)::int FROM metric_events WHERE code='RATE_LIMITED' AND created_at>now()-interval '5 minutes') AS "rateLimitTriggers",
 (SELECT count(*)::int FROM subscriptions WHERE status IN('PAST_DUE','GRACE_PERIOD')) AS "pastDueAccounts",
 (SELECT count(*)::int FROM internal_admin_audit WHERE created_at>now()-interval '5 minutes') AS "staffActions",
 (SELECT count(*)::int FROM durable_jobs WHERE state='PENDING') AS "workerPending",
 (SELECT count(*)::int FROM durable_jobs WHERE state='RUNNING') AS "workerRunning",
 (SELECT count(*)::int FROM durable_jobs WHERE state='DEAD') AS "deadJobs",
 (SELECT COALESCE(sum(attempts),0)::text FROM durable_jobs) AS "workerAttempts",
 (SELECT count(*)::int FROM audit_outbox WHERE delivered_at IS NULL) AS "auditPending",
 (SELECT count(*)::int FROM alert_events WHERE delivered_at IS NULL) AS "alertsPending",
 (SELECT count(*)::int FROM billing_provider_jobs WHERE status='PENDING') AS "billingBacklog",
 (SELECT count(*)::int FROM operational_security_events WHERE code='CUSTOMER_LOGIN_FAILED' AND created_at>now()-interval '5 minutes') AS "authFailures",
 (SELECT count(*)::int FROM operational_security_events WHERE code='ADMIN_LOGIN_FAILED' AND created_at>now()-interval '5 minutes') AS "staffFailures",
 (SELECT count(*)::int FROM asset_verifications WHERE verification_status='FAILED' AND created_at>now()-interval '5 minutes') AS "verificationFailures",
 (SELECT count(*)::int FROM metric_events WHERE code='BILLING_WEBHOOK_FAILED' AND created_at>now()-interval '5 minutes') AS "billingFailures",
 (SELECT count(*)::int FROM development_entitlements e WHERE e.protected_bytes<>(SELECT COALESCE(sum(a.verified_size_bytes),0) FROM assets a WHERE a.user_id=e.user_id AND a.status='PROTECTED' AND a.privacy_deleted_at IS NULL) OR e.reserved_bytes<>(SELECT COALESCE(sum(u.expected_size_bytes),0) FROM upload_sessions u WHERE u.user_id=e.user_id AND u.reservation_released_at IS NULL)) AS "quotaMismatches",
 (SELECT COALESCE(avg(duration_ms),0)::float FROM metric_events WHERE code='VERIFICATION_LATENCY' AND created_at>now()-interval '1 hour') AS "verificationLatencyMs"`)).rows[0];}
 async check(){if(!await this.db.isReachable()){await this.emit('DATABASE_UNAVAILABLE','CRITICAL',{available:false});return{database:'UNAVAILABLE'};}const storage=await this.storage.isHealthy().catch(()=>false);if(!storage)await this.emit('STORAGE_UNAVAILABLE','CRITICAL',{available:false});const m=await this.metrics();if(!m)throw new Error('Metrics unavailable');for(const[code,key,threshold]of [['AUTH_FAILURE_SPIKE','authFailures',alertThresholds.AUTH_FAILURE_SPIKE],['ADMIN_AUTH_ANOMALY','staffFailures',alertThresholds.ADMIN_AUTH_ANOMALY],['VERIFICATION_FAILURE_SPIKE','verificationFailures',alertThresholds.VERIFICATION_FAILURE_SPIKE],['BILLING_FAILURE_SPIKE','billingFailures',alertThresholds.BILLING_FAILURE_SPIKE],['WORKER_BACKLOG','workerPending',alertThresholds.WORKER_BACKLOG],['DEAD_JOBS','deadJobs',1],['AUDIT_BACKLOG','auditPending',1000],['RECONCILIATION_BACKLOG','billingBacklog',100],['QUOTA_MISMATCH','quotaMismatches',1],['DELETION_STUCK','deletionStuck',1],['DELETION_RETRY_THRESHOLD','deletionRetryThreshold',1],['TOMBSTONE_REPLAY','tombstoneReplays',1],['OBJECT_REAPPEARANCE','objectReappearance',1],['LATE_PAYMENT_REACTIVATION_REVIEW','lateDeletionPayments',1],['PRIVACY_EXPORT_FAILURE','exportFailures',1],['RETENTION_ABNORMAL_VOLUME','retentionAbnormalVolume',1]] as const)if(Number(m[key])>=threshold)await this.emit(code,'WARNING',{count:Number(m[key])});const cost=await storageCostEstimate(this.db);if(cost.budgetExceeded)await this.emit('UNPAID_STORAGE_BUDGET','WARNING',{count:cost.overQuotaAccounts});return{database:'UP',storage:storage?'UP':'UNAVAILABLE',...m};}
 async flushAlerts(){const pending=(await this.db.query('SELECT id,code,severity,summary FROM alert_events WHERE delivered_at IS NULL ORDER BY created_at,id LIMIT 100')).rows;let delivered=0;for(const e of pending)try{await this.sink.send({...e,summary:alertSummary(e.summary)} as Alert);await this.db.query('UPDATE alert_events SET delivered_at=now() WHERE id=$1',[e.id]);delivered++;}catch{}return{delivered,pending:pending.length-delivered};}
 async sampleIntegrity(){const candidate=(await this.db.query("SELECT * FROM assets WHERE status='PROTECTED' AND privacy_deleted_at IS NULL AND verified_size_bytes<=33554432 ORDER BY cleanup_integrity_checked_at NULLS FIRST,id LIMIT 1")).rows[0];if(!candidate)return{sampled:0};let result;try{this.storage.assertBinding(candidate.storage_provider,candidate.storage_binding);result=await this.storage.verifyObject(candidate.storage_object_key,Number(candidate.verified_size_bytes),candidate.expected_checksum,candidate.storage_version_id);}catch{result={ok:false,code:'STORAGE_UNAVAILABLE'};}
  const valid=result.ok&&result.versionId===candidate.storage_version_id&&result.sizeBytes===Number(candidate.verified_size_bytes)&&result.checksum===candidate.expected_checksum;await this.db.query('UPDATE assets SET cleanup_integrity_state=$2,cleanup_integrity_checked_at=now() WHERE id=$1 AND status=\'PROTECTED\' AND storage_version_id=$3',[candidate.id,valid?'VERIFIED':result.ok||['OBJECT_MISSING','SIZE_MISMATCH','CHECKSUM_MISMATCH','IMMUTABILITY_UNAVAILABLE'].includes(result.code)?'INVALID':'UNKNOWN',candidate.storage_version_id]);if(!valid)await this.emit('PROTECTED_INTEGRITY_ISSUE','CRITICAL',{count:1});return{sampled:1,valid};
 }
}
