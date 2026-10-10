import {CanActivate,ExecutionContext,Inject,Injectable,HttpException,ServiceUnavailableException} from '@nestjs/common';
import {createHmac,randomBytes,randomUUID} from 'node:crypto';
import {DatabaseService} from '../database.service';
import {limitSetting} from './config';
export abstract class RateLimitStore{abstract consume(key:string,limit:number,windowSeconds:number):Promise<boolean>;}
export class MemoryRateLimitStore extends RateLimitStore{
 private values=new Map<string,{count:number,end:number}>();
 async consume(key:string,limit:number,windowSeconds:number){const now=Date.now();let v=this.values.get(key);if(!v||v.end<=now){for(const[k,x]of this.values)if(x.end<=now)this.values.delete(k);if(this.values.size>=10000)return false;v={count:0,end:now+windowSeconds*1000};this.values.set(key,v);}v.count=Math.min(v.count+1,limit+1);return v.count<=limit;}
}
@Injectable() export class PostgresRateLimitStore extends RateLimitStore{
 constructor(@Inject(DatabaseService)private db:DatabaseService){super();}
 async consume(key:string,limit:number,windowSeconds:number){return this.db.transaction(async c=>{
  // Bound cardinality under concurrent first-use keys. Existing-key updates serialize only their row.
  if(!(await c.query('SELECT key_hash FROM distributed_limits WHERE key_hash=$1',[key])).rowCount){await c.query('SELECT pg_advisory_xact_lock(101001)');if(Number((await c.query('SELECT count(*) n FROM distributed_limits')).rows[0].n)>=limitSetting('RATE_LIMIT_MAX_KEYS',100000,1000000))return false;}
  const r=(await c.query(`INSERT INTO distributed_limits(key_hash,count,expires_at) VALUES($1,1,now()+$3*interval '1 second') ON CONFLICT(key_hash) DO UPDATE SET count=CASE WHEN distributed_limits.expires_at<=now() THEN 1 ELSE LEAST(distributed_limits.count+1,$2+1) END,expires_at=CASE WHEN distributed_limits.expires_at<=now() THEN now()+$3*interval '1 second' ELSE distributed_limits.expires_at END RETURNING count`,[key,limit,windowSeconds])).rows[0];return r.count<=limit;
 });}
}
@Injectable() export class DistributedRateLimiter {
 private secret=process.env.RATE_LIMIT_KEY_SECRET??randomBytes(32).toString('hex');
 constructor(@Inject(RateLimitStore)private store:RateLimitStore){}
 key(category:string,identity:string){return createHmac('sha256',this.secret).update(category+'\0'+identity.slice(0,512)).digest('hex');}
 async check(category:string,identity:string,limit:number,window=60){try{if(!await this.store.consume(this.key(category,identity),limit,window))throw new HttpException('Too many requests',429);}catch(e){if(e instanceof HttpException)throw e;throw new ServiceUnavailableException('Request protection unavailable');}}
}
@Injectable() export class ProductionRateGuard implements CanActivate{
 constructor(@Inject(DistributedRateLimiter)private limiter:DistributedRateLimiter,@Inject(DatabaseService)private db:DatabaseService){}
 async canActivate(ctx:ExecutionContext){const r=ctx.switchToHttp().getRequest(),action=ctx.getClass().name+'.'+ctx.getHandler().name,prod=process.env.NODE_ENV==='production',auth=/login|register|forgot|reset|resend|challenge|redeem/i.test(action)||/^PrivacyController\.(request|export|cancel)$/.test(action),mutation=r.method!=='GET';
  const limit=limitSetting(auth?'AUTH_IP_LIMIT':mutation?'MUTATION_IP_LIMIT':'READ_IP_LIMIT',prod?(auth?30:mutation?120:600):5000);
  try{await this.limiter.check(action+':ip',r.ip??'unknown',limit,auth?600:60);
  if(typeof r.body?.email==='string')await this.limiter.check(action+':account',r.body.email.trim().toLowerCase(),prod?15:5000,600);
  if(typeof r.headers?.authorization==='string')await this.limiter.check(action+':session',r.headers.authorization,prod?(mutation?60:300):5000);
  return true;}catch(e){const code=e instanceof HttpException&&e.getStatus()===429?'RATE_LIMITED':'PROTECTION_UNAVAILABLE';try{await this.db.query('INSERT INTO metric_events(id,code) VALUES($1,$2)',[randomUUID(),code]);}catch{}throw e;}
 }
}
