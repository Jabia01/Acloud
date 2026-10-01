// Local-only validation against the running API/web, PostgreSQL and Mailpit.
// Creates random .invalid fixture accounts; never prints credentials or mail links.
import assert from 'node:assert/strict';
import { randomUUID, createHash } from 'node:crypto';
import pg from 'pg';
process.loadEnvFile('.env');
const databaseURL = new URL(process.env.DATABASE_URL);
assert.ok(['127.0.0.1', 'localhost'].includes(databaseURL.hostname), 'Local database required');
const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL, connectionTimeoutMillis: 3000 });
const base = process.env.API_BASE_URL || 'http://127.0.0.1:3001';
assert.ok(['127.0.0.1', 'localhost'].includes(new URL(base).hostname), 'Local API required');
const email = `live-${randomUUID()}@example.invalid`;
let password = randomUUID().repeat(2);
const hash = token => createHash('sha256').update(token).digest('hex');
let stage = 'setup';
const pass = message => console.info(`PASS ${message}`);
async function api(method, path, body, bearer, status = 200) {
  stage = `${method} ${path}`;
  const response = await fetch(new URL(path, base), { method, headers: { 'Content-Type': 'application/json', ...(bearer ? { Authorization: `Bearer ${bearer}` } : {}) }, ...(body ? { body: JSON.stringify(body) } : {}), redirect: 'error', signal: AbortSignal.timeout(10000) });
  assert.equal(response.status, status, `${stage}: unexpected HTTP status`);
  const data = await response.json();
  assert.ok(!/password_hash|passwordHash|token_hash|tokenHash|\$argon2/.test(JSON.stringify(data)), 'Unsafe API fields');
  assert.ok(!JSON.stringify(data).includes(password), 'Password exposed');
  if (path !== '/auth/login') assert.ok(!JSON.stringify(data).includes('sessionToken'), 'Unexpected issued credential');
  return data;
}
async function capturedToken(kind) {
  stage = 'Mailpit capture';
  const messages = await (await fetch('http://127.0.0.1:8025/api/v1/messages')).json();
  const record = messages.messages.find(item => item.To.some(recipient => recipient.Address.toLowerCase() === email) && item.Subject === (kind === 'verify' ? 'Verify your email' : 'Reset your password'));
  assert.ok(record, 'Mail was not captured');
  const message = await (await fetch(`http://127.0.0.1:8025/api/v1/message/${record.ID}`)).json();
  const link = message.Text.match(/https?:\/\/[^\s]+/)[0];
  const url = new URL(link); assert.equal(url.searchParams.has('token'), false);
  const raw = new URLSearchParams(url.hash.slice(1)).get('token'); assert.match(raw, /^[A-Za-z0-9_-]{43}$/);
  return raw;
}
try {
  await api('GET', '/health');
  const registration = await api('POST', '/auth/register', { email, password }, null, 202);
  const duplicate = await api('POST', '/auth/register', { email: `  ${email.toUpperCase()}  `, password }, null, 202);
  assert.deepEqual(registration, duplicate);
  const users = await pool.query('SELECT id,password_hash FROM users WHERE email_normalized=$1', [email]); assert.equal(users.rowCount, 1); assert.match(users.rows[0].password_hash, /^\$argon2id\$/);
  pass('live registration, normalized duplicate suppression and Argon2id storage');
  const device = { identifier: randomUUID(), displayName: 'Live validation device', platform: 'ios' };
  const first = await api('POST', '/auth/login', { email, password, device });
  const session = (await pool.query('SELECT token_hash FROM sessions WHERE id=$1', [first.sessionId])).rows[0]; assert.equal(session.token_hash, hash(first.sessionToken));
  const me = await api('GET', '/me', null, first.sessionToken); assert.equal(me.emailVerified, false);
  pass('live login, hashed bearer storage and authenticated /me');
  const verification = await capturedToken('verify');
  const verifyStored = (await pool.query('SELECT token_hash FROM email_verification_tokens WHERE user_id=$1', [users.rows[0].id])).rows[0]; assert.equal(verifyStored.token_hash, hash(verification));
  await api('POST', '/auth/email/verify', { token: verification }); await api('POST', '/auth/email/verify', { token: verification }, null, 400);
  assert.equal((await api('GET', '/me', null, first.sessionToken)).emailVerified, true);
  pass('actual SMTP/Mailpit capture, verification, hash storage and replay rejection');
  const otherDevice = { ...device, identifier: randomUUID() };
  const second = await api('POST', '/auth/login', { email, password, device: otherDevice });
  const sessions = await api('GET', '/sessions', null, first.sessionToken); assert.equal(sessions.length, 2);
  await api('DELETE', `/sessions/${second.sessionId}`, null, first.sessionToken); await api('GET', '/me', null, second.sessionToken, 401);
  pass('live session listing and individual revocation');
  const third = await api('POST', '/auth/login', { email, password, device: otherDevice });
  const devices = await api('GET', '/devices', null, first.sessionToken); assert.equal(devices.length, 2);
  const victimDevice = (await pool.query('SELECT id FROM devices WHERE user_id=$1 AND device_identifier=$2', [users.rows[0].id, otherDevice.identifier])).rows[0];
  await api('DELETE', `/devices/${victimDevice.id}`, null, first.sessionToken); await api('GET', '/me', null, third.sessionToken, 401);
  pass('live device listing, revocation and linked-session invalidation');
  await api('POST', '/auth/logout', {}, first.sessionToken); await api('GET', '/me', null, first.sessionToken, 401);
  pass('live logout and session replay rejection');
  const known = await api('POST', '/auth/password/forgot', { email }, null, 202);
  const unknown = await api('POST', '/auth/password/forgot', { email: `absent-${randomUUID()}@example.invalid` }, null, 202); assert.deepEqual(known, unknown);
  const reset = await capturedToken('reset');
  const resetStored = (await pool.query('SELECT token_hash FROM password_reset_tokens WHERE user_id=$1', [users.rows[0].id])).rows[0]; assert.equal(resetStored.token_hash, hash(reset));
  const beforeReset = await api('POST', '/auth/login', { email, password });
  const oldPassword = password; password = randomUUID().repeat(2);
  await api('POST', '/auth/password/reset', { token: reset, password });
  await api('GET', '/me', null, beforeReset.sessionToken, 401);
  await api('POST', '/auth/password/reset', { token: reset, password }, null, 400);
  await api('POST', '/auth/login', { email, password: oldPassword }, null, 401);
  const afterReset = await api('POST', '/auth/login', { email, password });
  await api('POST', '/auth/logout', {}, afterReset.sessionToken);
  pass('actual Mailpit password reset, non-enumeration, token hashing, single use, old-password rejection and session revocation');
  if (process.argv.includes('--web')) {
    const webBase = process.env.WEB_BASE_URL || 'http://localhost:3000';
    assert.ok(['localhost', '127.0.0.1'].includes(new URL(webBase).hostname), 'Local web required');
    for (const path of ['/register', '/login', '/account', '/forgot-password', '/reset-password', '/verify-email']) {
      const response = await fetch(new URL(path, webBase)); assert.equal(response.status, 200); assert.equal(response.headers.get('referrer-policy'), 'no-referrer');
    }
    const body = JSON.stringify({ email, password, device: { identifier: randomUUID(), displayName: 'Web validation', platform: 'web' } });
    const webLogin = origin => fetch(new URL('/api/auth/login', webBase), { method: 'POST', headers: { 'Content-Type': 'application/json', ...(origin ? { Origin: origin } : {}) }, body });
    assert.equal((await webLogin()).status, 403); assert.equal((await webLogin('https://attacker.invalid')).status, 403);
    const response = await webLogin(process.env.WEB_ORIGIN || 'http://localhost:3000'); assert.equal(response.status, 200);
    const json = await response.json(); assert.ok(!JSON.stringify(json).includes('sessionToken')); assert.ok(!JSON.stringify(json).includes('password_hash'));
    const cookie = response.headers.get('set-cookie'); assert.ok(cookie); assert.match(cookie, /HttpOnly/i); assert.match(cookie, /SameSite=strict/i); assert.match(cookie, /Secure/i); assert.ok(!/Domain=/i.test(cookie));
    const cookieHeader = cookie.split(';')[0];
    const me = await fetch(new URL('/api/auth/me', webBase), { headers: { Cookie: cookieHeader } }); assert.equal(me.status, 200); assert.equal((await me.json()).emailVerified, true);
    const logout = await fetch(new URL('/api/auth/logout', webBase), { method: 'POST', headers: { Cookie: cookieHeader, Origin: process.env.WEB_ORIGIN || 'http://localhost:3000', 'Content-Type': 'application/json' }, body: '{}' }); assert.equal(logout.status, 200);
    const revoked = await fetch(new URL('/api/auth/me', webBase), { headers: { Cookie: cookieHeader } }); assert.equal(revoked.status, 401);
    pass('six live web pages; missing/hostile-Origin rejection; HttpOnly Secure Strict host cookie; no browser JSON bearer; authenticated account and logout revocation');
  }
  pass('live fixture account remains in local development only, all issued sessions revoked; no passwords/tokens logged');
} catch {
  console.error(`Live validation failed at ${stage}; details suppressed to protect credentials.`); process.exitCode = 1;
} finally { await pool.end(); }
