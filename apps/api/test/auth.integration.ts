import 'reflect-metadata';
import { before, after, beforeEach, describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { Pool } from 'pg';
import { Test } from '@nestjs/testing';
import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { AppModule } from '../src/app.module';
import { AccountMailer, MemoryAccountMailer } from '../src/auth/mail';
import { AuthRateLimit } from '../src/auth/rate-limit';
import { SafeErrors } from '../src/auth/safe-errors';
import { digest } from '../src/auth/auth.service';
import { PasswordService } from '../src/auth/password.service';

describe('real PostgreSQL account security', { concurrency: false }, () => {
  let app: INestApplication;
  let pool: Pool;
  let admin: Pool;
  const originalURL = process.env.DATABASE_URL;
  const schema = `auth_test_${randomUUID().replaceAll('-', '')}`;
  const mail = new MemoryAccountMailer();
  // Fresh limiter per request for flow coverage. The actual guard is tested below
  // in a separate app and in unit tests; no application setting disables it.
  const flowLimiter = { canActivate: () => true };
  let address: string;
  let password: string;
  let userId: string;
  before(async () => {
    const url = new URL(originalURL!);
    assert.ok(['127.0.0.1', 'localhost'].includes(url.hostname), 'Integration requires a local database');
    admin = new Pool({ connectionString: originalURL });
    await admin.query(`CREATE SCHEMA ${schema}`);
    url.searchParams.set('options', `-c search_path=${schema}`);
    process.env.DATABASE_URL = url.href;
    const { migrate } = await import('../../../scripts/migrate.mjs');
    assert.equal(await migrate(), 3);
    assert.equal(await migrate(), 0);
    pool = new Pool({ connectionString: url.href });
    const module = await Test.createTestingModule({ imports: [AppModule] }).overrideProvider(AccountMailer).useValue(mail).overrideGuard(AuthRateLimit).useValue(flowLimiter).compile();
    app = module.createNestApplication(); app.useGlobalFilters(new SafeErrors()); await app.init();
  });
  after(async () => {
    await app?.close(); await pool?.end();
    // Drop only this generated test fixture schema, never application/customer tables.
    if (admin) { await admin.query(`DROP SCHEMA IF EXISTS ${schema} CASCADE`); await admin.end(); }
    if (originalURL === undefined) delete process.env.DATABASE_URL; else process.env.DATABASE_URL = originalURL;
  });
  const post = (path: string, body: unknown) => request(app.getHttpServer()).post(path).send(body);
  const get = (path: string, token: string) => request(app.getHttpServer()).get(path).set('Authorization', `Bearer ${token}`);
  const remove = (path: string, token: string) => request(app.getHttpServer()).delete(path).set('Authorization', `Bearer ${token}`);
  const login = (deviceIdentifier?: string) => post('/auth/login', { email: address, password, ...(deviceIdentifier ? { device: { identifier: deviceIdentifier, displayName: 'Fixture phone', platform: 'ios' } } : {}) });
  beforeEach(async () => {
    address = `fixture-${randomUUID()}@example.invalid`; password = randomUUID().repeat(2);
    await post('/auth/register', { email: address, password }).expect(202);
    userId = (await pool.query('SELECT id FROM users WHERE email_normalized=$1', [address])).rows[0].id;
  });
  const message = (kind: 'verify' | 'reset') => mail.messages.filter(m => m.to === address && m.kind === kind).at(-1)!;
  const safe = (value: unknown, raw?: string) => {
    const data = JSON.stringify(value);
    assert.ok(!/password_hash|passwordHash|token_hash|tokenHash|\$argon2|DATABASE_URL/.test(data));
    assert.ok(!data.includes(password));
    if (raw) assert.ok(!data.includes(raw));
  };
  test('registration, normalization, duplicate suppression and password hashing', async () => {
    const response = await post('/auth/register', { email: `  ${address.toUpperCase()}  `, password }).expect(202);
    assert.deepEqual(response.body, { message: 'If eligible, an email has been sent.' });
    const users = await pool.query('SELECT password_hash FROM users WHERE email_normalized=$1', [address]);
    assert.equal(users.rowCount, 1); assert.match(users.rows[0].password_hash, /^\$argon2id\$/);
    assert.notEqual(users.rows[0].password_hash, password); safe(response.body, message('verify').token);
    assert.equal(mail.messages.filter(m => m.to === address && m.kind === 'verify').length, 1);
  });
  test('password policy rejects short input without truncating long passwords', async () => {
    await post('/auth/register', { email: `short-${randomUUID()}@example.invalid`, password: 'x'.repeat(11) }).expect(400);
    const longAddress = `long-${randomUUID()}@example.invalid`; const long = '🔒'.repeat(100);
    await post('/auth/register', { email: longAddress, password: long }).expect(202);
    await post('/auth/login', { email: longAddress, password: long }).expect(200);
    await post('/auth/login', { email: longAddress, password: long.slice(0, -2) }).expect(401);
  });
  test('concurrent registration creates exactly one account and verification mail', async () => {
    const fresh = `parallel-${randomUUID()}@example.invalid`;
    const responses = await Promise.all([post('/auth/register', { email: fresh, password }), post('/auth/register', { email: fresh.toUpperCase(), password })]);
    assert.deepEqual(responses.map(r => r.status), [202, 202]);
    assert.equal((await pool.query('SELECT id FROM users WHERE email_normalized=$1', [fresh])).rowCount, 1);
    assert.equal(mail.messages.filter(m => m.to.toLowerCase() === fresh).length, 1);
  });
  test('correct login succeeds; wrong/unknown/disabled credentials have identical responses', async () => {
    await login().expect(200);
    const wrong = await post('/auth/login', { email: address, password: randomUUID() }).expect(401);
    const absent = await post('/auth/login', { email: `absent-${randomUUID()}@example.invalid`, password }).expect(401);
    await pool.query("UPDATE users SET status='DISABLED' WHERE id=$1", [userId]);
    const disabled = await login().expect(401);
    assert.deepEqual(wrong.body, { message: 'Invalid credentials' }); assert.deepEqual(absent.body, wrong.body); assert.deepEqual(disabled.body, wrong.body);
  });
  test('session issuance stores only its hash; /me is authenticated and returns safe fields', async () => {
    await request(app.getHttpServer()).get('/me').expect(401);
    const response = await login().expect(200); const raw = response.body.sessionToken;
    assert.match(raw, /^[A-Za-z0-9_-]{43}$/);
    const row = (await pool.query('SELECT * FROM sessions WHERE id=$1', [response.body.sessionId])).rows[0];
    assert.equal(row.token_hash, digest(raw)); assert.ok(!JSON.stringify(row).includes(raw));
    const me = await get('/me', raw).expect(200);
    assert.deepEqual(Object.keys(me.body).sort(), ['email', 'emailVerified', 'id', 'status']); assert.equal(me.body.emailVerified, false); safe(me.body, raw);
    const sessionList = await get('/sessions', raw).expect(200); safe(sessionList.body, raw); assert.equal(sessionList.body[0].current, true);
    assert.equal(response.headers['cache-control'], 'no-store');
  });
  test('session expiration and disabled account invalidate existing credentials', async () => {
    const first = await login().expect(200);
    await pool.query("UPDATE sessions SET expires_at=now()-interval '1 second' WHERE id=$1", [first.body.sessionId]);
    await get('/me', first.body.sessionToken).expect(401);
    const second = await login().expect(200);
    await pool.query("UPDATE users SET status='DISABLED' WHERE id=$1", [userId]);
    await get('/me', second.body.sessionToken).expect(401);
  });
  test('logout revokes the session and rejects replay', async () => {
    const response = await login().expect(200); const raw = response.body.sessionToken;
    const logout = await post('/auth/logout', {}).set('Authorization', `Bearer ${raw}`).expect(200); safe(logout.body, raw);
    await get('/me', raw).expect(401);
  });
  test('individual and all-other session revocation preserve the current session', async () => {
    const current = await login().expect(200); const second = await login().expect(200); const third = await login().expect(200);
    await remove(`/sessions/${second.body.sessionId}`, current.body.sessionToken).expect(200);
    await get('/me', second.body.sessionToken).expect(401);
    await remove('/sessions', current.body.sessionToken).expect(200);
    await get('/me', third.body.sessionToken).expect(401); await get('/me', current.body.sessionToken).expect(200);
    const audits = await pool.query("SELECT event FROM auth_audit_events WHERE user_id=$1 AND event IN ('SESSION_REVOKED','OTHER_SESSIONS_REVOKED')", [userId]); assert.equal(audits.rowCount, 2);
  });
  test('verification token is hashed, succeeds once, and updates /me', async () => {
    const raw = message('verify').token;
    const row = (await pool.query('SELECT token_hash FROM email_verification_tokens WHERE user_id=$1', [userId])).rows[0]; assert.equal(row.token_hash, digest(raw));
    const response = await post('/auth/email/verify', { token: raw }).expect(200); safe(response.body, raw);
    await post('/auth/email/verify', { token: raw }).expect(400);
    const session = await login().expect(200); assert.equal((await get('/me', session.body.sessionToken)).body.emailVerified, true);
  });
  test('expired verification fails; resend invalidates the old token', async () => {
    const old = message('verify').token;
    await pool.query("UPDATE email_verification_tokens SET expires_at=now()-interval '1 second' WHERE user_id=$1", [userId]);
    await post('/auth/email/verify', { token: old }).expect(400);
    await post('/auth/email/resend', { email: address }).expect(202);
    const fresh = message('verify').token; assert.notEqual(fresh, old);
    await post('/auth/email/verify', { token: fresh }).expect(200);
  });
  test('concurrent verification consumption has exactly one winner', async () => {
    const raw = message('verify').token;
    const responses = await Promise.all([post('/auth/email/verify', { token: raw }), post('/auth/email/verify', { token: raw })]);
    assert.deepEqual(responses.map(r => r.status).sort(), [200, 400]);
  });
  test('forgot-password does not enumerate; reset token stored only as a hash', async () => {
    const known = await post('/auth/password/forgot', { email: address }).expect(202);
    const absent = await post('/auth/password/forgot', { email: `unknown-${randomUUID()}@example.invalid` }).expect(202);
    assert.deepEqual(known.body, absent.body); safe(known.body, message('reset').token);
    const row = (await pool.query('SELECT token_hash FROM password_reset_tokens WHERE user_id=$1', [userId])).rows[0]; assert.equal(row.token_hash, digest(message('reset').token));
  });
  test('expired reset fails and does not change password', async () => {
    await post('/auth/password/forgot', { email: address }).expect(202); const raw = message('reset').token;
    await pool.query("UPDATE password_reset_tokens SET expires_at=now()-interval '1 second' WHERE user_id=$1", [userId]);
    await post('/auth/password/reset', { token: raw, password: randomUUID() }).expect(400); await login().expect(200);
  });
  test('reset succeeds once, revokes all sessions and invalidates all outstanding reset links', async () => {
    const first = await login().expect(200); const second = await login().expect(200);
    await post('/auth/password/forgot', { email: address }).expect(202); const raw = message('reset').token; const replacement = randomUUID().repeat(2);
    const reset = await post('/auth/password/reset', { token: raw, password: replacement }).expect(200); safe(reset.body, raw);
    await post('/auth/password/reset', { token: raw, password: randomUUID() }).expect(400);
    await get('/me', first.body.sessionToken).expect(401); await get('/me', second.body.sessionToken).expect(401);
    await login().expect(401); password = replacement; await login().expect(200);
  });
  test('concurrent password reset cannot replay or double-consume a token', async () => {
    await post('/auth/password/forgot', { email: address }).expect(202); const raw = message('reset').token;
    const responses = await Promise.all([post('/auth/password/reset', { token: raw, password: randomUUID() }), post('/auth/password/reset', { token: raw, password: randomUUID() })]);
    assert.deepEqual(responses.map(r => r.status).sort(), [200, 400]);
  });
  test('a login verified before a concurrent reset cannot issue an old-password session', async () => {
    await post('/auth/password/forgot', { email: address }).expect(202);
    const raw = message('reset').token;
    const passwords = app.get(PasswordService);
    const originalVerify = passwords.verify.bind(passwords);
    let notify!: () => void; let release!: () => void;
    const verified = new Promise<void>(resolve => { notify = resolve; });
    const resume = new Promise<void>(resolve => { release = resolve; });
    passwords.verify = async (hash, value) => { const result = await originalVerify(hash, value); notify(); await resume; return result; };
    const pending = login().then(response => response);
    try {
      await verified;
      await post('/auth/password/reset', { token: raw, password: randomUUID() }).expect(200);
      release(); assert.equal((await pending).status, 401);
      assert.equal((await pool.query('SELECT id FROM sessions WHERE user_id=$1 AND revoked_at IS NULL', [userId])).rowCount, 0);
    } finally { release(); passwords.verify = originalVerify; }
  });
  test('device registration/listing/revocation invalidates related sessions only', async () => {
    const current = await login().expect(200); const identifier = randomUUID();
    const deviceSession = await login(identifier).expect(200); const secondDeviceSession = await login(identifier).expect(200);
    const devices = await get('/devices', current.body.sessionToken).expect(200); assert.equal(devices.body.length, 1); safe(devices.body, deviceSession.body.sessionToken);
    const deviceId = devices.body[0].id;
    await remove(`/devices/${deviceId}`, current.body.sessionToken).expect(200);
    await get('/me', deviceSession.body.sessionToken).expect(401); await get('/me', secondDeviceSession.body.sessionToken).expect(401); await get('/me', current.body.sessionToken).expect(200);
    await login(identifier).expect(401);
    const registration = await post('/devices', { identifier: randomUUID(), displayName: 'Browser fixture', platform: 'web' }).set('Authorization', `Bearer ${current.body.sessionToken}`).expect(200); assert.ok(registration.body.id);
  });
  test('tenant isolation prevents revoking another account sessions or devices', async () => {
    const victim = await login(randomUUID()).expect(200); const victimDevice = (await get('/devices', victim.body.sessionToken)).body[0].id;
    const attackerEmail = `other-${randomUUID()}@example.invalid`;
    await post('/auth/register', { email: attackerEmail, password }).expect(202);
    const attacker = await post('/auth/login', { email: attackerEmail, password }).expect(200);
    await remove(`/sessions/${victim.body.sessionId}`, attacker.body.sessionToken).expect(200);
    await remove(`/devices/${victimDevice}`, attacker.body.sessionToken).expect(200);
    await get('/me', victim.body.sessionToken).expect(200);
  });
  test('database errors are sanitized without credentials, SQL or stack traces', async () => {
    await pool.query('ALTER TABLE users RENAME TO users_temporarily_unavailable');
    try { const response = await login().expect(503); assert.deepEqual(response.body, { message: 'Service unavailable' }); }
    finally { await pool.query('ALTER TABLE users_temporarily_unavailable RENAME TO users'); }
  });
  test('real HTTP rate guard protects registration and login', async () => {
    const module = await Test.createTestingModule({ imports: [AppModule] }).overrideProvider(AccountMailer).useValue(mail).compile();
    const limitedApp = module.createNestApplication(); limitedApp.useGlobalFilters(new SafeErrors()); await limitedApp.init();
    try {
      for (let attempt = 0; attempt < 5; attempt++) await request(limitedApp.getHttpServer()).post('/auth/register').send({ email: address, password }).expect(202);
      const limited = await request(limitedApp.getHttpServer()).post('/auth/register').send({ email: address, password }).expect(429); assert.equal(limited.headers['retry-after'], '600');
      for (let attempt = 0; attempt < 15; attempt++) await request(limitedApp.getHttpServer()).post('/auth/login').send({ email: address, password: randomUUID() }).expect(401);
      await request(limitedApp.getHttpServer()).post('/auth/login').send({ email: address, password }).expect(429);
    } finally { await limitedApp.close(); }
  });
});
