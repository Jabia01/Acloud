import {CanActivate,ExecutionContext,Inject,Injectable,UnauthorizedException,HttpException} from '@nestjs/common';
import {createHash,randomUUID} from 'node:crypto';
import type {Request} from 'express';
import {AdminService,AdminPrincipal} from './service';
import {enabled} from './policy';
import {DatabaseService} from '../database.service';
export type AdminRequest=Request & {admin:AdminPrincipal};
@Injectable()
export class AdminGuard implements CanActivate {
 constructor(@Inject(AdminService)private readonly service:AdminService){}
 async canActivate(context:ExecutionContext){enabled();const r=context.switchToHttp().getRequest<AdminRequest>(),header=r.headers.authorization;if(!header||!/^Bearer [A-Za-z0-9_-]{43}$/.test(header))throw new UnauthorizedException('Staff authentication required');r.admin=await this.service.authenticate(header.slice(7));return true;}
}
@Injectable()
export class AdminRateLimit implements CanActivate {
 private buckets=new Map<string,{count:number;end:number}>();
 constructor(@Inject(DatabaseService)private readonly db:DatabaseService){}
 private consume(key:string,limit:number){const now=Date.now();let b=this.buckets.get(key);if(!b||b.end<=now){if(this.buckets.size>=10000){for(const [k,v]of this.buckets)if(v.end<=now)this.buckets.delete(k);if(this.buckets.size>=10000)throw new HttpException('Too many requests',429);}b={count:0,end:now+60000};this.buckets.set(key,b);}if(++b.count>limit)throw new HttpException('Too many requests',429);}
 async canActivate(context:ExecutionContext){enabled();const r=context.switchToHttp().getRequest<AdminRequest>(),login=context.getHandler().name==='login';const category=login?'login':r.method!=='GET'?'mutate':r.path?.includes('/users')?'lookup':'read';
  try{this.consume(createHash('sha256').update(`ip:${r.ip||'unknown'}:${category}`).digest('hex'),login?10:120);this.consume(createHash('sha256').update(`${category}:${login&&typeof r.body?.email==='string'?r.body.email.trim().toLowerCase():r.admin?.adminId||'unknown'}`).digest('hex'),login?5:category==='mutate'?10:category==='lookup'?20:60);}catch{await this.db.query("INSERT INTO operational_security_events(id,code,admin_id) VALUES($1,'ADMIN_RATE_LIMIT',$2)",[randomUUID(),r.admin?.adminId??null]);throw new HttpException('Too many requests',429);}return true;}
}
