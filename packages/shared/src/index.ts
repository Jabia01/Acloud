export interface HealthResponse {
  status: 'ok' | 'degraded';
  checks: { api: 'up'; database: 'up' | 'down' };
}

// Runtime validation at the network boundary, shared with the web client.
export function isHealthy(value: unknown): value is HealthResponse {
  if (typeof value !== 'object' || value === null) return false;
  const health = value as Partial<HealthResponse>;
  return health.status === 'ok' && health.checks?.api === 'up' && health.checks.database === 'up';
}

export type AssetStatus = 'QUEUED' | 'UPLOADING' | 'UPLOADED' | 'VERIFYING' | 'PROTECTED' | 'FAILED' | 'CANCELLED' | 'EXPIRED';
export interface AssetResponse { id: string; mediaType: 'image' | 'video' | 'test'; status: AssetStatus; sizeBytes: number | null }
export interface CreateUploadRequest { media_type: 'image' | 'video' | 'test'; expected_size_bytes: number; checksum_sha256: string; device_id?: string | null }
// A UI/network predicate only, never authority to grant protection on the server.
export function isProtectedAsset(value: unknown): value is AssetResponse & {status:'PROTECTED';sizeBytes:number} {
  if (!value || typeof value !== 'object') return false;
  const asset=value as Partial<AssetResponse>;
  return typeof asset.id === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(asset.id)
    && ['image','video','test'].includes(asset.mediaType ?? '') && asset.status === 'PROTECTED'
    && typeof asset.sizeBytes === 'number' && Number.isSafeInteger(asset.sizeBytes) && asset.sizeBytes > 0;
}
