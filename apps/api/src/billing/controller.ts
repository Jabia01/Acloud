import {Body,Controller,Get,Headers,HttpCode,Inject,Param,Post,Query,Req,UseGuards,CanActivate,ExecutionContext,Injectable,HttpException} from '@nestjs/common';
import type {RawBodyRequest} from '@nestjs/common';
import type {Request} from 'express';
import {SessionGuard,type AuthRequest} from '../auth/session.guard';
import {BillingService} from './service';
import {AdminGuard,AdminRateLimit,type AdminRequest} from '../admin/guard';
import {AdminService} from '../admin/service';
import {DatabaseService} from '../database.service';
import {uuid} from '../auth/input';
@Injectable()
export class BillingRateLimit implements CanActivate {private buckets=new Map<string,{n:number,end:number}>();canActivate(ctx:ExecutionContext){const r=ctx.switchToHttp().getRequest<AuthRequest>(),key=r.principal.userId,now=Date.now();let b=this.buckets.get(key);if(!b||b.end<now){if(this.buckets.size>=10000){for(const[k,v]of this.buckets)if(v.end<now)this.buckets.delete(k);if(this.buckets.size>=10000)throw new HttpException('Too many requests',429);}this.buckets.set(key,b={n:0,end:now+60000});}if(++b.n>10)throw new HttpException('Too many requests',429);return true;}}
@Controller('billing')
export class BillingController{
 constructor(@Inject(BillingService)private readonly service:BillingService){}
 @Get('plans')plans(){return this.service.plans();}
 @Get('subscription')@UseGuards(SessionGuard)current(@Req()r:AuthRequest){return this.service.current(r.principal);}
 @Get('history')@UseGuards(SessionGuard)history(@Req()r:AuthRequest,@Query()q:Record<string,unknown>){return this.service.history(r.principal,q);}
 @Post('checkout')@HttpCode(200)@UseGuards(SessionGuard,BillingRateLimit)checkout(@Req()r:AuthRequest,@Body()b:unknown,@Headers('idempotency-key')key:string){return this.service.checkout(r.principal,b,key);}
 @Post('cancel')@HttpCode(200)@UseGuards(SessionGuard,BillingRateLimit)cancel(@Req()r:AuthRequest,@Body()b:unknown,@Headers('idempotency-key')key:string){return this.service.cancel(r.principal,b,key);}
 @Post('webhooks/paystack')@HttpCode(200)webhook(@Req()r:RawBodyRequest<Request>,@Headers('x-paystack-signature')sig:string){return this.service.webhook(r.rawBody!,sig??'');}
}
@Controller('internal/billing')@UseGuards(AdminGuard,AdminRateLimit)
export class AdminBillingController{
 constructor(@Inject(BillingService)private readonly billing:BillingService,@Inject(AdminService)private readonly admin:AdminService,@Inject(DatabaseService)private readonly db:DatabaseService){}
 @Get()async overview(@Req()r:AdminRequest){return this.db.transaction(async c=>{await this.admin.authorize(c,r.admin,'admins');return this.billing.adminOverview();});}
 @Get('accounts')async accounts(@Req()r:AdminRequest,@Query()q:Record<string,unknown>){return this.db.transaction(async c=>{await this.admin.authorize(c,r.admin,'admins');return this.billing.adminAccounts(q);});}
 @Get('users/:id')async user(@Req()r:AdminRequest,@Param('id')id:string){return this.db.transaction(async c=>{await this.admin.authorize(c,r.admin,'admins');return this.billing.adminUser(uuid(id));});}
 @Post('users/:id/reconcile')@HttpCode(200)async reconcile(@Req()r:AdminRequest,@Param('id')id:string,@Body()b:unknown,@Headers('idempotency-key')key:string){id=uuid(id);await this.admin.operate(r.admin,'admins','BILLING_RECONCILIATION_REQUEST','user',id,b,key,[],async()=>({before:{},after:{requested:true},result:{requested:true}}));return this.db.transaction(async c=>{await this.admin.authorize(c,r.admin,'admins');return this.billing.reconcile(id,true);});}
}
