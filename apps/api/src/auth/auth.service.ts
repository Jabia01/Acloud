import {betaConfiguration} from '../beta/config';
import {limitSetting} from '../hardening/config';
import { BadRequestException, ConflictException, Inject, Injectable, UnauthorizedException } from '@nestjs/common';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import type { PoolClient } from 'pg';
import { DatabaseService } from '../database.service';
import { PasswordService } from './password.service';
import { AccountMailer } from './mail';
import type { DeviceInput } from './input';

export const GENERIC_ACCOUNT_MESSAGE = { message: 'If eligible, an email has been sent.' };
const INVALID = 'Invalid credentials';
export const digest = (value: string) => createHash('sha256').update(value).digest('hex');
const issue = () => randomBytes(32).toString('base64url');
const safeUser = (row: Record<string, any>) => ({ id: row.id, email: row.email, emailVerified: row.email_verified_at !== null, status: row.status });
export interface Principal { userId: string; sessionId: string; deviceId: string | null }

@Injectable()
export class AuthService {
  constructor(
    @Inject(DatabaseService) private readonly db: DatabaseService,
    @Inject(PasswordService) private readonly passwords: PasswordService,
    @Inject(AccountMailer) private readonly mail: AccountMailer,
  ) {}
  private async audit(client: PoolClient, userId: string, event: string, targetId: string | null = null) {
    await client.query('INSERT INTO auth_audit_events (id,user_id,event,target_id) VALUES ($1,$2,$3,$4)', [randomUUID(), userId, event, targetId]);
  }
  private async lockUser(client: PoolClient, userId: string) {
    const result = await client.query('SELECT * FROM users WHERE id=$1 FOR UPDATE', [userId]);
    const user = result.rows[0];
    if (!user || user.status !== 'ACTIVE' || user.privacy_state !== 'ACTIVE') throw new UnauthorizedException('Authentication required');
    return user;
  }
  private async deliver(to: string, kind: 'verify' | 'reset', raw: string) {
    // Do not turn mail failures into an account-existence oracle. Resend is available.
    // Development transport only; production token mail is queued transactionally.
    try { await this.mail.send({ to, kind, token: raw }); } catch { /* deliberately no sensitive logging */ }
  }
  async register(display: string, normalized: string, password: string) {
    // Hash even for duplicate attempts to reduce the obvious fast-path oracle.
    if(process.env.NODE_ENV==='production'||betaConfiguration().enabled)throw new UnauthorizedException('Customer onboarding awaits private beta approval');
    const hash = await this.passwords.hash(password);
    const raw = issue();
    const created = await this.db.transaction(async client => {
      const result = await client.query('INSERT INTO users (id,email,email_normalized,password_hash) VALUES ($1,$2,$3,$4) ON CONFLICT (email_normalized) DO NOTHING RETURNING id', [randomUUID(), display, normalized, hash]);
      if (!result.rows[0]) return false;
      await client.query("INSERT INTO email_verification_tokens (id,user_id,token_hash,expires_at) VALUES ($1,$2,$3,now()+interval '24 hours')", [randomUUID(), result.rows[0].id, digest(raw)]);
      return true;
    });
    if (created) await this.deliver(display, 'verify', raw);
    return GENERIC_ACCOUNT_MESSAGE;
  }
  private async upsertDevice(client: PoolClient, userId: string, input: DeviceInput) {
    await client.query('SELECT pg_advisory_xact_lock(hashtextextended($1,101002))',[input.identifier]);
    const existing = await client.query('SELECT id,revoked_at,platform FROM devices WHERE user_id=$1 AND device_identifier=$2 FOR UPDATE', [userId, input.identifier]);
    if (existing.rows[0] && (existing.rows[0].revoked_at || existing.rows[0].platform !== input.platform)) throw new BadRequestException('Device registration unavailable');
    if(!existing.rowCount&&Number((await client.query('SELECT count(*) n FROM devices WHERE user_id=$1 AND revoked_at IS NULL',[userId])).rows[0].n)>=(betaConfiguration().enabled?betaConfiguration().maxDevices:limitSetting('MAX_ACCOUNT_DEVICES',20,1000)))throw new BadRequestException('Device limit reached');
    if(!existing.rowCount&&Number((await client.query('SELECT count(DISTINCT user_id) n FROM devices WHERE device_identifier=$1 AND revoked_at IS NULL',[input.identifier])).rows[0].n)>=limitSetting('MAX_DEVICE_ACCOUNTS',5,100))throw new BadRequestException('Device relationship requires review');
    const result = await client.query(`INSERT INTO devices (id,user_id,device_identifier,display_name,platform,app_version,os_version)
      VALUES ($1,$2,$3,$4,$5,$6,$7) ON CONFLICT (user_id,device_identifier) DO UPDATE SET display_name=EXCLUDED.display_name,platform=EXCLUDED.platform,app_version=EXCLUDED.app_version,os_version=EXCLUDED.os_version,last_seen_at=now() RETURNING id`, [randomUUID(), userId, input.identifier, input.displayName, input.platform, input.appVersion, input.osVersion]);
    return result.rows[0].id as string;
  }
  async login(normalized: string, password: string, device: DeviceInput | null, signOutOtherSessions=false) {
    const found = await this.db.query('SELECT * FROM users WHERE email_normalized=$1', [normalized]);
    const candidate = found.rows[0];
    const valid = await this.passwords.verify(candidate?.password_hash, password);
    if (!valid || !candidate || candidate.status !== 'ACTIVE') { await this.db.query("INSERT INTO operational_security_events(id,code) VALUES($1,'CUSTOMER_LOGIN_FAILED')",[randomUUID()]); throw new UnauthorizedException(INVALID); }
    const raw = issue();
    return this.db.transaction(async client => {
      const locked = await client.query('SELECT * FROM users WHERE id=$1 FOR UPDATE', [candidate.id]);
      const user = locked.rows[0];
      if (!user || user.status !== 'ACTIVE' || user.privacy_state !== 'ACTIVE') throw new UnauthorizedException(INVALID);
      // Reset might have changed the password while expensive verification ran.
      if (user.password_hash !== candidate.password_hash) throw new UnauthorizedException(INVALID);
      // Explicit password-authenticated recovery; never inferred from a full account.
      if(signOutOtherSessions){
        const revoked=await client.query('UPDATE sessions SET revoked_at=now() WHERE user_id=$1 AND revoked_at IS NULL AND expires_at>now() RETURNING id',[user.id]);
        for(const row of revoked.rows)await this.audit(client,user.id,'SESSION_REVOKED',row.id);
      }
      let deviceId: string | null = null;
      if (device) {
        try { deviceId = await this.upsertDevice(client, user.id, device); }
        catch (error) { if (error instanceof BadRequestException) throw new UnauthorizedException(INVALID); throw error; }
      }
      // Password verification and the user lock precede rotation. Only replace this
      // account's registered browser sessions; never rotate a native device session.
      if (device?.platform === 'web' && deviceId) {
        const replaced = await client.query(`UPDATE sessions s SET revoked_at=now() FROM devices d
          WHERE s.user_id=$1 AND s.device_id=$2 AND d.id=s.device_id AND d.user_id=s.user_id
          AND d.platform='web' AND d.revoked_at IS NULL AND s.revoked_at IS NULL AND s.expires_at>now()
          RETURNING s.id`, [user.id,deviceId]);
        for (const row of replaced.rows) await this.audit(client,user.id,'SESSION_REVOKED',row.id);
      }
      if(Number((await client.query('SELECT count(*) n FROM sessions WHERE user_id=$1 AND revoked_at IS NULL AND expires_at>now()',[user.id])).rows[0].n)>=limitSetting('MAX_ACTIVE_SESSIONS',10,1000))throw new ConflictException('Session limit reached. Sign out of another browser or device, then try again.');
      const session = await client.query("INSERT INTO sessions (id,user_id,token_hash,device_id,expires_at) VALUES ($1,$2,$3,$4,now()+interval '30 days') RETURNING id,expires_at", [randomUUID(), user.id, digest(raw), deviceId]);
      await this.audit(client, user.id, 'LOGIN', session.rows[0].id);
      // This is the one endpoint permitted to return the issued bearer credential.
      return { sessionToken: raw, sessionId: session.rows[0].id, expiresAt: session.rows[0].expires_at, user: safeUser(user) };
    });
  }
  async authenticate(raw: string): Promise<Principal> {
    if (!/^[A-Za-z0-9_-]{43}$/.test(raw)) throw new UnauthorizedException('Authentication required');
    const hash = digest(raw);
    const found = await this.db.query('SELECT user_id FROM sessions WHERE token_hash=$1', [hash]);
    if (!found.rows[0]) throw new UnauthorizedException('Authentication required');
    return this.db.transaction(async client => {
      await this.lockUser(client, found.rows[0]!.user_id);
      const result = await client.query(`SELECT s.id,s.user_id,s.device_id FROM sessions s
        LEFT JOIN devices d ON d.id=s.device_id WHERE s.token_hash=$1 AND s.revoked_at IS NULL AND s.expires_at>now() AND (s.device_id IS NULL OR d.revoked_at IS NULL)`, [hash]);
      const session = result.rows[0];
      if (!session) throw new UnauthorizedException('Authentication required');
      await client.query("UPDATE sessions SET last_seen_at=now() WHERE id=$1 AND last_seen_at<now()-interval '1 minute'", [session.id]);
      if (session.device_id) await client.query("UPDATE devices SET last_seen_at=now() WHERE id=$1 AND last_seen_at<now()-interval '1 minute'", [session.device_id]);
      return { userId: session.user_id, sessionId: session.id, deviceId: session.device_id };
    });
  }
  async me(principal: Principal) {
    const result = await this.db.query('SELECT id,email,email_verified_at,status FROM users WHERE id=$1', [principal.userId]);
    return safeUser(result.rows[0]!);
  }
  async sessions(principal: Principal) {
    const result = await this.db.query('SELECT id,device_id,created_at,last_seen_at,expires_at FROM sessions WHERE user_id=$1 AND revoked_at IS NULL AND expires_at>now() ORDER BY created_at DESC LIMIT 100', [principal.userId]);
    return result.rows.map(row => ({ id: row.id, deviceId: row.device_id, createdAt: row.created_at, lastSeenAt: row.last_seen_at, expiresAt: row.expires_at, current: row.id === principal.sessionId }));
  }
  async revokeSession(principal: Principal, id: string, event = 'SESSION_REVOKED') {
    await this.db.transaction(async client => {
      await this.lockUser(client, principal.userId);
      const result = await client.query('UPDATE sessions SET revoked_at=COALESCE(revoked_at,now()) WHERE id=$1 AND user_id=$2 RETURNING id', [id, principal.userId]);
      if (result.rowCount) await this.audit(client, principal.userId, event, id);
    });
    return { message: 'Session revoked.' }; // Same response for unowned IDs.
  }
  async revokeOthers(principal: Principal) {
    await this.db.transaction(async client => {
      await this.lockUser(client, principal.userId);
      await client.query('UPDATE sessions SET revoked_at=now() WHERE user_id=$1 AND id<>$2 AND revoked_at IS NULL', [principal.userId, principal.sessionId]);
      await this.audit(client, principal.userId, 'OTHER_SESSIONS_REVOKED');
    });
    return { message: 'Other sessions revoked.' };
  }
  async devices(principal: Principal) {
    const result = await this.db.query('SELECT id,display_name,platform,app_version,os_version,last_seen_at,created_at FROM devices WHERE user_id=$1 AND revoked_at IS NULL ORDER BY created_at DESC LIMIT 100', [principal.userId]);
    return result.rows.map(row => ({ id: row.id, displayName: row.display_name, platform: row.platform, appVersion: row.app_version, osVersion: row.os_version, lastSeenAt: row.last_seen_at, createdAt: row.created_at }));
  }
  async registerDevice(principal: Principal, input: DeviceInput) {
    return this.db.transaction(async client => {
      await this.lockUser(client, principal.userId);
      const id = await this.upsertDevice(client, principal.userId, input);
      await client.query('UPDATE sessions SET device_id=$1 WHERE id=$2 AND user_id=$3', [id, principal.sessionId, principal.userId]);
      return { id };
    });
  }
  async revokeDevice(principal: Principal, id: string) {
    await this.db.transaction(async client => {
      await this.lockUser(client, principal.userId);
      const result = await client.query('UPDATE devices SET revoked_at=COALESCE(revoked_at,now()) WHERE id=$1 AND user_id=$2 RETURNING id', [id, principal.userId]);
      if (result.rowCount) {
        await client.query('UPDATE sessions SET revoked_at=COALESCE(revoked_at,now()) WHERE device_id=$1 AND user_id=$2', [id, principal.userId]);
        await this.audit(client, principal.userId, 'DEVICE_REVOKED', id);
      }
    });
    return { message: 'Device revoked.' };
  }
  async requestToken(normalized: string, kind: 'verify' | 'reset') {
    const found = await this.db.query('SELECT id FROM users WHERE email_normalized=$1', [normalized]);
    const raw = issue();
    let recipient: string | null = null;
    if (found.rows[0]) {
      try { recipient = await this.db.transaction(async client => {
        const result = await client.query('SELECT * FROM users WHERE id=$1 FOR UPDATE', [found.rows[0]!.id]);
        const user = result.rows[0];
        if (!user || user.status !== 'ACTIVE' || (kind === 'verify' && user.email_verified_at !== null)) return null;
        const table = kind === 'verify' ? 'email_verification_tokens' : 'password_reset_tokens';
        // Constant table identifiers only, never derived from a request.
        await client.query(`UPDATE ${table} SET used_at=now() WHERE user_id=$1 AND used_at IS NULL`, [user.id]);
        await client.query(`INSERT INTO ${table} (id,user_id,token_hash,expires_at) VALUES ($1,$2,$3,now()+interval '${kind === 'verify' ? '24 hours' : '30 minutes'}')`, [randomUUID(), user.id, digest(raw)]);
        if(this.mail.enqueueInTransaction){
          // Issuance, old-token invalidation and encrypted delivery job commit together.
          await this.mail.enqueueInTransaction({to:user.email,kind,token:raw},client,user.id);
          return null;
        }
        if(process.env.NODE_ENV==='production')throw new Error('Transactional account email required');
        return user.email as string;
      }); } catch {
        // Rollback preserves prior links; public responses must not reveal account existence.
        await this.db.query("INSERT INTO operational_security_events(id,code) VALUES($1,'ACCOUNT_EMAIL_QUEUE_FAILED')",[randomUUID()]).catch(()=>{});
      }
    }
    if (recipient) await this.deliver(recipient, kind, raw);
    return GENERIC_ACCOUNT_MESSAGE;
  }
  async consumeToken(raw: string, kind: 'verify' | 'reset', password?: string) {
    const table = kind === 'verify' ? 'email_verification_tokens' : 'password_reset_tokens';
    const hash = digest(raw);
    const candidate = await this.db.query(`SELECT user_id FROM ${table} WHERE token_hash=$1`, [hash]);
    if (!candidate.rows[0]) throw new BadRequestException('Invalid or expired token');
    const newHash = kind === 'reset' ? await this.passwords.hash(password!) : null;
    await this.db.transaction(async client => {
      const user = await this.lockUser(client, candidate.rows[0]!.user_id);
      const consumed = await client.query(`UPDATE ${table} SET used_at=now() WHERE token_hash=$1 AND used_at IS NULL AND expires_at>now() RETURNING id`, [hash]);
      if (!consumed.rowCount) throw new BadRequestException('Invalid or expired token');
      if (kind === 'verify') {
        await client.query('UPDATE users SET email_verified_at=COALESCE(email_verified_at,now()),updated_at=now() WHERE id=$1', [user.id]);
        await client.query('UPDATE email_verification_tokens SET used_at=COALESCE(used_at,now()) WHERE user_id=$1', [user.id]);
        await this.audit(client, user.id, 'EMAIL_VERIFIED');
      } else {
        await client.query('UPDATE users SET password_hash=$1,updated_at=now() WHERE id=$2', [newHash, user.id]);
        await client.query('UPDATE password_reset_tokens SET used_at=COALESCE(used_at,now()) WHERE user_id=$1', [user.id]);
        await client.query('UPDATE sessions SET revoked_at=COALESCE(revoked_at,now()) WHERE user_id=$1', [user.id]);
        await this.audit(client, user.id, 'PASSWORD_RESET');
      }
    });
    return { message: kind === 'verify' ? 'Email verified.' : 'Password reset. Sign in again.' };
  }
}
