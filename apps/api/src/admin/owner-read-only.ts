import {createHash} from 'node:crypto';
import {ForbiddenException} from '@nestjs/common';
import type {Permission} from './policy';

const uuid=/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i;
export type OwnerReadOnly={adminId:string;expiresAt:string};
export function ownerReadOnlyConfiguration(e:NodeJS.ProcessEnv=process.env,now=Date.now()):OwnerReadOnly|null {
 const flag=e.STAFF_OWNER_READ_ONLY_ENABLED;
 if(flag===undefined||flag==='false')return null;
 if(flag!=='true'||e.NODE_ENV!=='production'||e.APP_ENV!=='staging'||e.BETA_ENABLED!=='false'||e.INTERNAL_ADMIN_ENABLED!=='true'||e.ADMIN_MFA_REQUIRED!=='true')throw new Error('Invalid owner read-only configuration');
 const id=e.STAFF_OWNER_READ_ONLY_ADMIN_ID,expiry=e.STAFF_OWNER_READ_ONLY_EXPIRES_AT;
 if(!uuid.test(id??'')||!expiry||!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/.test(expiry)||!Number.isFinite(Date.parse(expiry))||Date.parse(expiry)>now+30*86400000)throw new Error('Invalid owner read-only binding');
 // An expired window denies staff access without crashing customer services on restart.
 return{adminId:id!.toLowerCase(),expiresAt:expiry};
}
const reads=new Set(['/internal/me','/internal/overview','/internal/storage','/internal/system','/internal/security','/internal/users','/internal/uploads','/internal/devices','/internal/audit']);
const auth=new Set(['/internal/login','/internal/auth/challenge']);
const readPermissions=new Set<Permission>(['overview','users','uploads','devices','audit','security','system']);
export function assertOwnerReadOnlyPermission(adminId:string,permission:Permission,role?:string,e:NodeJS.ProcessEnv=process.env){
 const c=ownerReadOnlyConfiguration(e);if(!c)return;
 if(c.adminId!==adminId.toLowerCase()||Date.now()>=Date.parse(c.expiresAt)||!readPermissions.has(permission)||role!==undefined&&role!=='SUPERADMIN')throw new ForbiddenException('Owner console is read-only');
}
export function ownerReadOnlyIdentity(adminId:string){const c=ownerReadOnlyConfiguration();return c&&c.adminId===adminId.toLowerCase()?{ownerReadOnly:true,readOnlyExpiresAt:c.expiresAt}:{};}
type Query={query:(sql:string,values?:unknown[])=>Promise<{rows:Record<string,any>[]}>};
export async function allowOwnerReadOnlyRequest(db:Query,r:{headers:Record<string,unknown>;body?:unknown},method:string,path:string,c:OwnerReadOnly){
 if(Date.now()>=Date.parse(c.expiresAt))throw new ForbiddenException('Owner preview expired');
 if(method==='POST'&&auth.has(path)){
  const b=r.body as Record<string,unknown>|undefined;
  if(!b||typeof b.email!=='string'||b.email.length>254)throw new ForbiddenException('Owner access required');
  const row=(await db.query(`SELECT a.id FROM internal_admins a WHERE a.id=$1 AND a.email_normalized=$2 AND a.status='ACTIVE' AND a.role='SUPERADMIN' AND EXISTS(SELECT 1 FROM staff_credentials k WHERE k.admin_id=a.id AND k.revoked_at IS NULL)`,[c.adminId,b.email.trim().toLowerCase()])).rows[0];
  if(!row)throw new ForbiddenException('Owner access required');
  // Existing controller password/MFA validation and rate limits still run next.
  return;
 }
 const allowedRead=method==='GET'&&(reads.has(path)||new RegExp(`^/internal/users/${uuid.source.slice(1,-1)}$`,'i').test(path));
 if(!allowedRead&&!(method==='POST'&&path==='/internal/logout'))throw new ForbiddenException('Owner console is read-only');
 const header=r.headers.authorization;
 if(typeof header!=='string'||!/^Bearer [A-Za-z0-9_-]{43}$/.test(header))throw new ForbiddenException('Owner access required');
 const row=(await db.query(`SELECT a.id FROM internal_admins a JOIN internal_admin_sessions s ON s.admin_id=a.id JOIN staff_credentials k ON k.id=s.mfa_credential_id AND k.admin_id=a.id WHERE a.id=$1 AND a.status='ACTIVE' AND a.role='SUPERADMIN' AND s.token_hash=$2 AND s.revoked_at IS NULL AND s.expires_at>now() AND s.last_seen_at>now()-interval '5 minutes' AND s.mfa_verified_at IS NOT NULL AND k.revoked_at IS NULL`,[c.adminId,createHash('sha256').update(header.slice(7)).digest('hex')])).rows[0];
 if(!row)throw new ForbiddenException('Owner access required');
 // AdminGuard rechecks the normal staff-session and role boundary next.
}
