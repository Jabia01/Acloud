import {lifecyclePolicy} from '../lifecycle/policy';
import {BadRequestException,ConflictException,ForbiddenException,Inject,Injectable,NotFoundException,UnauthorizedException} from '@nestjs/common';
import {randomBytes,randomUUID,createHash} from 'node:crypto';
import {DatabaseService} from '../database.service';import {PasswordService} from '../auth/password.service';import type {Principal} from '../auth/auth.service';import {ObjectStorageProvider} from '../uploads/storage';import {BillingProvider} from '../billing/provider';import {DurableJobs} from './jobs';import {limitSetting} from './config';
const hash=(v:string)=>createHash('sha256').update(v).digest('hex');
function body(value:unknown,allowed:string[]){if(!value||typeof value!=='object'||Array.isArray(value)||Object.keys(value).some(k=>!allowed.includes(k)))throw new BadRequestException('Invalid privacy request');return value as Record<string,any>;}
import {LifecycleService} from '../lifecycle/service';import {LifecycleExportService} from '../lifecycle/exports';import type {DurableJob} from './jobs';
@Injectable() export class PrivacyService {
 constructor(@Inject(DatabaseService)private db:DatabaseService,@Inject(PasswordService)private passwords:PasswordService,@Inject(DurableJobs)private jobs:DurableJobs,@Inject(LifecycleService)private lifecycle:LifecycleService,@Inject(LifecycleExportService)private exports:LifecycleExportService){}
 private async reauthenticate(p:Principal,password:unknown){if(typeof password!=='string'||password.length>4096)throw new UnauthorizedException('Reauthentication required');const user=(await this.db.query("SELECT * FROM users WHERE id=$1 AND status='ACTIVE' AND privacy_state='ACTIVE'",[p.userId])).rows[0];if(!user||!await this.passwords.verify(user.password_hash,password))throw new UnauthorizedException('Reauthentication required');return user;}
 requestDeletion(p:Principal,value:unknown){return this.lifecycle.request(p,value);}
 cancellation(value:unknown,cancel:boolean){return this.lifecycle.capability(value,cancel);}
 async export(p:Principal,value:unknown){const b=body(value,['password']);const verified=await this.reauthenticate(p,b.password);this.exports.ensureAvailable();const id=randomUUID();await this.db.transaction(async c=>{const current=(await c.query('SELECT * FROM users WHERE id=$1 FOR UPDATE',[p.userId])).rows[0];if(!current||current.status!=='ACTIVE'||current.privacy_state!=='ACTIVE'||current.password_hash!==verified.password_hash||!(await c.query('SELECT id FROM sessions WHERE id=$1 AND user_id=$2 AND revoked_at IS NULL AND expires_at>now()',[p.sessionId,p.userId])).rowCount)throw new UnauthorizedException();if(Number((await c.query("SELECT count(*) n FROM privacy_exports WHERE user_id=$1 AND state IN('PENDING','READY') AND expires_at>now()",[p.userId])).rows[0].n)>=3)throw new ConflictException('Export already pending');await c.query("INSERT INTO privacy_exports(id,user_id,expires_at) VALUES($1,$2,now()+$3*interval '1 hour')",[id,p.userId,lifecyclePolicy().exportHours]);await this.jobs.enqueue('PRIVACY_EXPORT',id,{exportId:id,userId:p.userId},c);});return{exportId:id,state:'PENDING'};}

 async exportHistory(p:Principal){return{items:(await this.db.query(`SELECT id AS "exportId",CASE WHEN expires_at<=now() THEN 'EXPIRED' ELSE state END AS state,created_at AS "createdAt",expires_at AS "expiresAt" FROM privacy_exports WHERE user_id=$1 ORDER BY created_at DESC,id DESC LIMIT 20`,[p.userId])).rows};}
 exportResult(p:Principal,id:string){if(!/^[a-f0-9-]{36}$/i.test(id))throw new BadRequestException();return this.exports.result(p,id);}
 buildExport(user:string,id:string){return this.exports.build(user,id);}
 processDeletion(user:string,id:string,job?:DurableJob){return this.lifecycle.run(user,id,job);}
}
