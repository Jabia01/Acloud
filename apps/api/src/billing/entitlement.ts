import {Inject,Injectable,ServiceUnavailableException} from '@nestjs/common';
import {randomUUID} from 'node:crypto';
import type {PoolClient} from 'pg';
import {DatabaseService} from '../database.service';
export const FREE_BYTES=5_000_000_000;
export async function billingAudit(c:PoolClient,userId:string,action:string,correlation:string,summary:Record<string,unknown>={}){await c.query('INSERT INTO billing_audit(id,user_id,action,correlation_id,summary) VALUES($1,$2,$3,$4,$5) ON CONFLICT(user_id,action,correlation_id) DO NOTHING',[randomUUID(),userId,action,correlation,JSON.stringify(summary)]);}
@Injectable()
export class EntitlementService {
 constructor(@Inject(DatabaseService)private readonly db:DatabaseService){}
 static async lock(c:PoolClient,userId:string){
  // Caller locks users first. All payment, quota and upload operations share this order.
  const s=(await c.query('SELECT * FROM subscriptions WHERE user_id=$1 FOR UPDATE',[userId])).rows[0];
  const now=Date.now();
  if(s&&Date.parse(s.current_period_end)<=now){
   if(s.scheduled_effective_at&&Date.parse(s.scheduled_effective_at)<=now){const plan=(await c.query('SELECT quota_bytes FROM billing_plans WHERE id=$1',[s.scheduled_plan_id])).rows[0];await c.query("UPDATE entitlements SET plan_id=$2,quota_bytes=$3,source='SUBSCRIPTION',effective_at=now(),updated_at=now() WHERE user_id=$1",[userId,s.scheduled_plan_id,plan.quota_bytes]);const price=(await c.query('SELECT billing_interval FROM billing_prices WHERE id=$1',[s.scheduled_price_id])).rows[0];const end=periodEnd(new Date(s.scheduled_effective_at),price.billing_interval);await c.query("UPDATE subscriptions SET plan_id=scheduled_plan_id,price_id=scheduled_price_id,billing_interval=$2,current_period_start=scheduled_effective_at,current_period_end=$3,grace_period_end=$3::timestamptz+interval '7 days',scheduled_plan_id=NULL,scheduled_price_id=NULL,scheduled_effective_at=NULL,status='ACTIVE',updated_at=now() WHERE user_id=$1",[userId,price.billing_interval,end]);await billingAudit(c,userId,'DOWNGRADE_EFFECTIVE',s.id,{quotaBytes:plan.quota_bytes});
   }else if(s.cancel_at_period_end || Date.parse(s.grace_period_end)<=now){if((await c.query("SELECT user_id FROM entitlements WHERE user_id=$1 AND source='SUBSCRIPTION'",[userId])).rowCount){await c.query("UPDATE subscriptions SET status=$2,updated_at=now() WHERE user_id=$1",[userId,s.cancel_at_period_end?'CANCELED':'EXPIRED']);await c.query("UPDATE entitlements SET plan_id='70000000-0000-4000-8000-000000000001',quota_bytes=$2,source='FREE',effective_at=now(),updated_at=now() WHERE user_id=$1",[userId,FREE_BYTES]);await billingAudit(c,userId,s.cancel_at_period_end?'CANCELLATION_EFFECTIVE':'GRACE_EXPIRED',s.id,{quotaBytes:FREE_BYTES});}}
   else if(s.status!=='GRACE_PERIOD'){await c.query("UPDATE subscriptions SET status='GRACE_PERIOD',updated_at=now() WHERE user_id=$1",[userId]);await billingAudit(c,userId,'GRACE_STARTED',s.id);}
  }
  const e=(await c.query(`SELECT e.*,p.code,p.display_name,m.quota_bytes AS manual_quota,m.expires_at AS manual_expiry FROM entitlements e JOIN billing_plans p ON p.id=e.plan_id LEFT JOIN manual_entitlements m ON m.user_id=e.user_id WHERE e.user_id=$1 FOR UPDATE OF e`,[userId])).rows[0];
  if(!e)throw new Error('Entitlement missing');const manual=e.manual_quota!==null&&(e.manual_expiry===null||Date.parse(e.manual_expiry)>now),quota=Number(manual?e.manual_quota:e.quota_bytes);
  if(e.manual_quota!==null&&e.manual_expiry!==null&&Date.parse(e.manual_expiry)<=now)await billingAudit(c,userId,'MANUAL_OVERRIDE_EXPIRED',`${userId}:${new Date(e.manual_expiry).toISOString()}`,{quotaBytes:e.quota_bytes});
  await c.query('INSERT INTO development_entitlements(user_id,quota_bytes) VALUES($1,$2) ON CONFLICT(user_id) DO UPDATE SET quota_bytes=EXCLUDED.quota_bytes',[userId,quota]);
  const usage=(await c.query('SELECT * FROM development_entitlements WHERE user_id=$1 FOR UPDATE',[userId])).rows[0];
  if(![quota,Number(usage.protected_bytes),Number(usage.reserved_bytes),Number(usage.protected_bytes)+Number(usage.reserved_bytes)].every(Number.isSafeInteger))throw new ServiceUnavailableException('Entitlement unavailable');
  return {planCode:e.code,planName:e.display_name,source:manual?'MANUAL_ADMIN':e.source,quotaBytes:quota,protectedBytes:Number(usage.protected_bytes),reservedBytes:Number(usage.reserved_bytes),remainingBytes:Math.max(0,quota-Number(usage.protected_bytes)-Number(usage.reserved_bytes)),overQuota:BigInt(usage.protected_bytes)+BigInt(usage.reserved_bytes)>BigInt(quota),manualExpiresAt:manual?e.manual_expiry:null};
 }
 async getEntitlement(userId:string){return this.db.transaction(async c=>{await c.query('SELECT id FROM users WHERE id=$1 FOR UPDATE',[userId]);return EntitlementService.lock(c,userId);});}
 static canReserveBytes(e:{remainingBytes:number},size:number){return Number.isSafeInteger(size)&&size>0&&size<=e.remainingBytes;}
}
export function periodEnd(start:Date,interval:string){const d=new Date(start),day=d.getUTCDate();d.setUTCDate(1);if(interval==='ANNUAL')d.setUTCFullYear(d.getUTCFullYear()+1);else d.setUTCMonth(d.getUTCMonth()+1);const last=new Date(Date.UTC(d.getUTCFullYear(),d.getUTCMonth()+1,0)).getUTCDate();d.setUTCDate(Math.min(day,last));return d;}
