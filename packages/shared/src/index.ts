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
