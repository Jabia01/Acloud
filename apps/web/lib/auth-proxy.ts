export const SESSION_COOKIE = process.env.NODE_ENV === 'production' ? '__Host-backup_session' : 'backup_session';
export function sameOrigin(request: Request, configuredOrigin = process.env.WEB_ORIGIN || 'http://localhost:3000'): boolean {
  // Fixed allowlisted origin; do not trust Host/X-Forwarded-Host as policy input.
  return request.headers.get('origin') === new URL(configuredOrigin).origin;
}
export function publicLogin(value: unknown): { sessionToken: string; expiresAt: string; body: Record<string, unknown> } | null {
  if (typeof value !== 'object' || value === null) return null;
  const data = value as Record<string, unknown>;
  if (typeof data.sessionToken !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(data.sessionToken) || typeof data.expiresAt !== 'string' || !Number.isFinite(Date.parse(data.expiresAt))) return null;
  if (typeof data.user !== 'object' || data.user === null) return null;
  const user = data.user as Record<string, unknown>;
  if (typeof user.id !== 'string' || typeof user.email !== 'string' || typeof user.emailVerified !== 'boolean' || user.status !== 'ACTIVE') return null;
  // Explicit fields; the browser never receives the opaque bearer or arbitrary upstream fields.
  return { sessionToken: data.sessionToken, expiresAt: data.expiresAt, body: { user: { id: user.id, email: user.email, emailVerified: user.emailVerified, status: user.status }, sessionId: data.sessionId, expiresAt: data.expiresAt } };
}
export function cookieOptions(expires?: Date, production = process.env.NODE_ENV === 'production') {
  return { httpOnly: true, secure: production, sameSite: 'strict' as const, path: '/', ...(expires ? { expires } : {}) };
}
