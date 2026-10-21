import {BetaPolicy} from '../beta/policy';
import {Inject,Injectable} from '@nestjs/common';
import {createHash,randomUUID} from 'node:crypto';
import type {PoolClient} from 'pg';
import {DatabaseService} from '../database.service';
export const jobKinds=['MAINTENANCE','RETENTION','BILLING_RECONCILE','ADMIN_UPLOAD_JOBS','INTEGRITY_SAMPLE','AUDIT_FORWARD','OBSERVABILITY','DELETION_SWEEP','ACCOUNT_DELETE','ACCOUNT_REDELETE','PRIVACY_EXPORT','EMAIL','UPLOAD_VERIFY','STALE_MULTIPART'] as const;
export type JobKind=typeof jobKinds[number];
export type DurableJob={id:string;kind:JobKind;payload:Record<string,string>;lease_id:string;attempts:number;max_attempts:number};
export function jobPayload(kind:JobKind,payload:Record<string,string>){if(!jobKinds.includes(kind)||Object.keys(payload).some(k=>!['userId','requestId','exportId','emailId','afterId','uploadId'].includes(k))||Object.values(payload).some(v=>typeof v!=='string'||!/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i.test(v)))throw new Error('Invalid durable job');const required:Partial<Record<JobKind,string[]>>={ACCOUNT_DELETE:['userId','requestId'],ACCOUNT_REDELETE:['userId','requestId'],PRIVACY_EXPORT:['userId','exportId'],EMAIL:['emailId'],UPLOAD_VERIFY:['userId','uploadId'],STALE_MULTIPART:['userId','uploadId']};if((required[kind]??[]).some(k=>!payload[k]))throw new Error('Missing durable job scope');}
@Injectable() export class DurableJobs{
 constructor(@Inject(DatabaseService)private db:DatabaseService,@Inject(BetaPolicy)private beta:BetaPolicy=new BetaPolicy(db)){}
 async enqueue(kind:JobKind,key:string,payload:Record<string,string>={},c?:PoolClient){jobPayload(kind,payload);const id=randomUUID(),dedupe=createHash('sha256').update(kind+'\0'+key).digest('hex');const q:{query(sql:string,values:unknown[]):Promise<{rows:any[]}>}=c??this.db;return(await q.query('INSERT INTO durable_jobs(id,kind,dedupe_key,payload) VALUES($1,$2,$3,$4) ON CONFLICT(dedupe_key) DO UPDATE SET dedupe_key=EXCLUDED.dedupe_key RETURNING id',[id,kind,dedupe,JSON.stringify(payload)])).rows[0].id as string;}
 async schedule(){return this.db.transaction(async c=>{const due=(await c.query('SELECT * FROM durable_schedules WHERE enabled AND next_at<=now() ORDER BY next_at LIMIT 20 FOR UPDATE SKIP LOCKED')).rows;for(const s of due){if((await c.query("SELECT id FROM durable_jobs WHERE kind=$1 AND payload='{}'::jsonb AND state IN('PENDING','RUNNING') LIMIT 1",[s.kind])).rowCount)continue;await this.enqueue(s.kind,s.name+':'+new Date(s.next_at).toISOString(),{},c);await c.query("UPDATE durable_schedules SET next_at=now()+interval '1 second'*interval_seconds WHERE name=$1",[s.name]);}return due.length;});}
 async claim():Promise<DurableJob|null>{const paused=await this.beta.pausedJobs();return this.db.transaction(async c=>{
  const exhausted=await c.query("UPDATE durable_jobs SET state='DEAD',last_error_code='LEASE_EXHAUSTED',finished_at=now() WHERE state='RUNNING' AND lease_until<=now() AND attempts>=max_attempts RETURNING kind,payload");
  for(const job of exhausted.rows)if(job.kind==='PRIVACY_EXPORT'){
   await c.query("UPDATE privacy_export_jobs SET state='FAILED' WHERE id=$1 AND user_id=$2 AND state='BUILDING'",[job.payload.exportId,job.payload.userId]);
   await c.query("UPDATE privacy_exports SET state='FAILED' WHERE id=$1 AND user_id=$2 AND state='PENDING'",[job.payload.exportId,job.payload.userId]);
  }
  const r=(await c.query("SELECT id FROM durable_jobs WHERE NOT(kind=ANY($1::text[])) AND attempts<max_attempts AND ((state='PENDING' AND available_at<=now()) OR (state='RUNNING' AND lease_until<=now())) ORDER BY available_at,id LIMIT 1 FOR UPDATE SKIP LOCKED",[paused])).rows[0];if(!r)return null;
  return(await c.query("UPDATE durable_jobs SET state='RUNNING',attempts=attempts+1,lease_id=$2,lease_until=now()+interval '20 minutes' WHERE id=$1 RETURNING *",[r.id,randomUUID()])).rows[0];
 });}
 async renew(job:DurableJob){if(!(await this.db.query("UPDATE durable_jobs SET lease_until=now()+interval '20 minutes' WHERE id=$1 AND lease_id=$2 AND state='RUNNING' AND lease_until>now() RETURNING id",[job.id,job.lease_id])).rowCount)throw new Error('Worker lease lost');}
 async complete(job:DurableJob){return(await this.db.query("UPDATE durable_jobs SET state='SUCCEEDED',finished_at=now(),lease_until=NULL WHERE id=$1 AND lease_id=$2 AND state='RUNNING' AND lease_until>now() RETURNING id",[job.id,job.lease_id])).rowCount===1;}
 async fail(job:DurableJob){const delay=Math.min(3600,15*2**Math.min(job.attempts,8));await this.db.transaction(async c=>{
  const updated=await c.query("UPDATE durable_jobs SET state=CASE WHEN attempts>=max_attempts THEN 'DEAD' ELSE 'PENDING' END,available_at=now()+$3*interval '1 second',last_error_code='JOB_FAILED',lease_until=NULL WHERE id=$1 AND lease_id=$2 AND state='RUNNING' RETURNING state",[job.id,job.lease_id,delay]);
  if(job.kind==='PRIVACY_EXPORT'&&updated.rows[0]?.state==='DEAD'){
   await c.query("UPDATE privacy_export_jobs SET state='FAILED' WHERE id=$1 AND user_id=$2 AND state='BUILDING'",[job.payload.exportId,job.payload.userId]);
   await c.query("UPDATE privacy_exports SET state='FAILED' WHERE id=$1 AND user_id=$2 AND state='PENDING'",[job.payload.exportId,job.payload.userId]);
  }
 });}
 async drain(handler:(job:DurableJob)=>Promise<void>,max=20,shouldStop:()=>boolean=()=>false){let processed=0,failed=0;for(let i=0;i<Math.min(max,100)&&!shouldStop();i++){const j=await this.claim();if(!j)break;try{jobPayload(j.kind,j.payload);await handler(j);if(!await this.complete(j))throw new Error('Lease lost');processed++;}catch{await this.fail(j);failed++;}}return{processed,failed};}
}
