import { createHash, createHmac } from 'node:crypto';
export const lifecycleStates = ['ACTIVE', 'PAYMENT_PAST_DUE', 'GRACE_PERIOD', 'OVER_QUOTA', 'CANCELED_SUBSCRIPTION', 'DELETION_REQUESTED', 'DELETION_COOLDOWN', 'DELETION_IN_PROGRESS', 'DELETION_PARTIAL', 'DELETED', 'LEGAL_HOLD', 'SECURITY_HOLD', 'RECOVERY_REVIEW'] as const;
function number(e: NodeJS.ProcessEnv, key: string, fallback: number, min: number, max: number) { const n = Number(e[key] ?? fallback); if (!Number.isInteger(n) || n < min || n > max)
    throw new Error('Invalid lifecycle configuration'); return n; }
function bool(e: NodeJS.ProcessEnv, key: string) { if (e[key] !== undefined && !['true', 'false'].includes(e[key]!))
    throw new Error('Invalid lifecycle boolean'); return e[key] === 'true'; }
export function lifecyclePolicy(e: NodeJS.ProcessEnv = process.env) { for(const name of ['PRIVACY_EXPORT_KEY','LIFECYCLE_IDENTITY_HMAC_KEY'])if(e[name]&&!/^[a-f0-9]{64}$/.test(e[name]!))throw new Error('Invalid lifecycle encryption configuration');const p = { execution: bool(e, 'ACCOUNT_DELETION_EXECUTION_ENABLED'), retention: bool(e, 'RETENTION_EXECUTION_ENABLED'), approved: bool(e, 'PRIVACY_RETENTION_APPROVED'), cooldown: number(e, 'DELETION_COOLDOWN_SECONDS', 7 * 86400, e.NODE_ENV==='production'?86400:0, 30 * 86400), batch: number(e, 'LIFECYCLE_BATCH_SIZE', 50, 1, 100), retryLimit: number(e, 'LIFECYCLE_RETRY_LIMIT', 8, 1, 20), exportHours: number(e, 'PRIVACY_EXPORT_RETENTION_HOURS', 24, 1, 168), exportBatch: number(e, 'PRIVACY_EXPORT_BATCH_SIZE', 250, 1, 500) }; if (p.execution && (!e.LIFECYCLE_LEDGER_DIR || !/^[a-f0-9]{64}$/.test(e.LIFECYCLE_LEDGER_KEY ?? '')))
    throw new Error('Independent encrypted deletion ledger required'); if ((p.execution || p.retention) && e.NODE_ENV === 'production' && !p.approved)
    throw new Error('Reviewed production retention policy required'); return p; }
export function sha(v: string) { return createHash('sha256').update(v).digest('hex'); }
export function identityHMAC(email: string, key: string) { if (!/^[a-f0-9]{64}$/.test(key))
    throw new Error('Identity HMAC key required'); return createHmac('sha256', Buffer.from(key, 'hex')).update('IDENTITY:v1:' + email.trim().toLowerCase()).digest('hex'); }
export function body(value: unknown, keys: string[]) { if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).some(k => !keys.includes(k)))
    throw new Error('Invalid lifecycle request'); return value as Record<string, any>; }
export const retentionCategories = ['upload_sessions', 'multipart_sessions', 'failed_jobs', 'audit_logs', 'auth_events', 'security_events', 'billing_records', 'deletion_records', 'tombstones', 'privacy_exports', 'temporary_artifacts', 'restore_temp_files', 'cleanup_proofs', 'support_logs', 'invites'];
