import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { sameOrigin, publicLogin, cookieOptions } from '../lib/auth-proxy';
test('requires the fixed trusted Origin for cookie-authenticated mutations', () => {
  assert.equal(sameOrigin(new Request('http://localhost:3000/api/auth/login')), false);
  assert.equal(sameOrigin(new Request('http://localhost:3000/api/auth/login', { headers: { Origin: 'https://attacker.invalid' } })), false);
  assert.equal(sameOrigin(new Request('http://attacker.invalid/api/auth/login', { headers: { Origin: 'http://localhost:3000' } })), true); // Policy never derives from Host.
});
test('strips bearer credentials from browser JSON and validates issuance', () => {
  const raw = randomBytes(32).toString('base64url');
  const result = publicLogin({ sessionToken: raw, expiresAt: new Date(Date.now() + 10000).toISOString(), user: { id: 'fixture', email: 'test@example.invalid', emailVerified: false, status: 'ACTIVE', password_hash: 'must not forward' }, password_hash: 'must not forward' });
  assert.equal(result?.sessionToken, raw); assert.ok(!JSON.stringify(result?.body).includes(raw)); assert.ok(!JSON.stringify(result?.body).includes('password_hash'));
  assert.equal(publicLogin({ sessionToken: 'invalid' }), null);
});
test('cookies are HttpOnly, host-scoped, SameSite Strict and secure in production', () => {
  const options = cookieOptions(undefined, true); assert.equal(options.httpOnly, true); assert.equal(options.secure, true); assert.equal(options.sameSite, 'strict'); assert.equal(options.path, '/'); assert.ok(!('domain' in options));
});

test('network origins require explicit development configuration and remain disabled in production', () => {
  const env: Record<string, string | undefined> = process.env;
  const previousMode = env.NODE_ENV, previousOrigins = env.DEV_WEB_ORIGINS;
  const request = (origin: string) => new Request('http://localhost:3000/api/auth/login', {headers: {Origin: origin}});
  try {
    env.NODE_ENV = 'development';
    delete env.DEV_WEB_ORIGINS;
    assert.equal(sameOrigin(request('http://192.168.1.217:3000')), false);
    env.DEV_WEB_ORIGINS = 'http://192.168.1.217:3000';
    assert.equal(sameOrigin(request('http://192.168.1.217:3000')), true);
    assert.equal(sameOrigin(request('http://192.168.1.218:3000')), false);
    assert.equal(sameOrigin(request('https://attacker.invalid')), false);
    env.NODE_ENV = 'production';
    assert.equal(sameOrigin(request('http://192.168.1.217:3000')), false);
  } finally {
    if (previousMode === undefined) delete env.NODE_ENV; else env.NODE_ENV = previousMode;
    if (previousOrigins === undefined) delete env.DEV_WEB_ORIGINS; else env.DEV_WEB_ORIGINS = previousOrigins;
  }
});
