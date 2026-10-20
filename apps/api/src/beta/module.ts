import {ownerPaymentTestConfiguration} from '../../../../infrastructure/railway/owner-payment-test.cjs';
import {ownerReadOnlyConfiguration,allowOwnerReadOnlyRequest} from '../admin/owner-read-only';
import {ownerTestConfigured} from './owner-test';
import {UploadModule} from '../uploads/upload.module';
import {BetaErrorReporter,ErrorSink,PendingErrorSink} from './errors';
import {Body,Controller,Get,Global,Inject,Module,Param,Post,Req,UseGuards,UseInterceptors,HttpCode,CanActivate,ExecutionContext,Injectable,ForbiddenException} from '@nestjs/common';import {APP_GUARD} from '@nestjs/core';import {createHash} from 'node:crypto';import {DatabaseService} from '../database.service';import {AuthModule} from '../auth/auth.module';import {SessionGuard,type AuthRequest} from '../auth/session.guard';import {AuthNoStore} from '../auth/safe-errors';import {AdminModule} from '../admin/module';import {AdminGuard,type AdminRequest} from '../admin/guard';import {PasswordService} from '../auth/password.service';import {BetaPolicy} from './policy';import {BetaService} from './service';import {betaConfiguration,supportedVersion} from './config';
@Injectable()export class BetaRequestGuard implements CanActivate{
 constructor(@Inject(BetaPolicy)private policy:BetaPolicy,@Inject(DatabaseService)private db:DatabaseService){}
 async canActivate(ctx:ExecutionContext){const cfg=betaConfiguration();const r=ctx.switchToHttp().getRequest(),method=r.method as string;let path:string;try{path=decodeURIComponent(String(r.path)).toLowerCase().replace(/\/+$/,'')||'/';}catch{throw new ForbiddenException();}if(path.startsWith('/internal/')){const owner=ownerReadOnlyConfiguration();if(owner){await allowOwnerReadOnlyRequest(this.db,r,method,path,owner);return true;}}if(!cfg.enabled){if(process.env.NODE_ENV==='production'&&process.env.APP_ENV==='staging'){if(method==='POST'&&path.startsWith('/uploads')){
 if(!ownerTestConfigured())throw new ForbiddenException('Beta backup disabled');
 const auth=r.headers.authorization;
 if(typeof auth!=='string'||!/^Bearer [A-Za-z0-9_-]{43}$/.test(auth))throw new ForbiddenException();
 const row=(await this.db.query('SELECT id,user_id,device_id FROM sessions WHERE token_hash=$1 AND revoked_at IS NULL AND expires_at>now()',[createHash('sha256').update(auth.slice(7)).digest('hex')])).rows[0];
 if(!row)throw new ForbiddenException();
 await this.policy.upload({userId:row.user_id,sessionId:row.id,deviceId:row.device_id});
 }
 if(method==='POST'&&(['/billing/checkout','/billing/plan-change','/billing/plan-change/undo'].includes(path)&&!ownerPaymentTestConfiguration()?.active||path.startsWith('/storage/free-up-space')))throw new ForbiddenException('Beta backup disabled');if(path.startsWith('/internal/'))await this.policy.gates(['STAFF_MFA']);if(method==='POST'&&path.endsWith('/download'))await this.policy.open('downloads');}return true;}
 if(path==='/auth/register')throw new ForbiddenException('Invitation required');if(path.startsWith('/internal/')&&process.env.NODE_ENV==='production')await this.policy.gates(['STAFF_MFA']);
 const routes:Record<string,string>={'/beta/redeem':'registration','/billing/checkout':'checkout','/billing/plan-change':'checkout','/billing/plan-change/undo':'checkout','/privacy/deletion':'account_deletion','/privacy/export':'privacy_export'};if(method==='POST'&&routes[path])await this.policy.open(routes[path]!);
 if(method==='POST'&&path.startsWith('/internal/')&&!['/internal/login','/internal/auth/challenge','/internal/logout','/internal/beta/switch'].includes(path))await this.policy.open('admin_mutation');
 if(['/billing/checkout','/billing/plan-change','/billing/plan-change/undo'].includes(path)&&method==='POST'){if(!cfg.payments)throw new ForbiddenException('Beta payments disabled');await this.policy.requireAdmission('PAYMENTS');}
 if(path.startsWith('/storage/free-up-space')){await this.policy.open('free_up_space');if(!cfg.freeUpSpace)throw new ForbiddenException('Beta cleanup disabled');}
 if(method==='POST'&&/^\/assets\/[a-f0-9-]+\/download$/.test(path))await this.policy.open('downloads');
 const upload=method==='POST'&&(path==='/uploads'||/^\/uploads\/[a-f0-9-]+\/(?:start|multipart|parts\/\d+\/authorize)$/.test(path));if(upload){if(process.env.NODE_ENV==='production'&&(!/^[a-f0-9]{64}$/.test(process.env.BETA_DEPLOYMENT_FINGERPRINT??'')||r.headers['x-environment-fingerprint']!==process.env.BETA_DEPLOYMENT_FINGERPRINT))throw new ForbiddenException('Environment fingerprint required');if(!supportedVersion(r.headers['x-app-version'],cfg.minimumVersion))throw new ForbiddenException('Supported app version required');const auth=r.headers.authorization;if(typeof auth!=='string'||!/^Bearer [A-Za-z0-9_-]{43}$/.test(auth))throw new ForbiddenException();const row=(await this.db.query('SELECT user_id FROM sessions WHERE token_hash=$1 AND revoked_at IS NULL AND expires_at>now()',[createHash('sha256').update(auth.slice(7)).digest('hex')])).rows[0];if(!row)throw new ForbiddenException();await this.policy.upload({userId:row.user_id,sessionId:'',deviceId:null});if(path.endsWith('/multipart')||path.includes('/parts/'))await this.policy.open('multipart');}
 return true;
 }
}
@Global()@Module({providers:[DatabaseService,BetaPolicy,BetaErrorReporter,{provide:ErrorSink,useClass:PendingErrorSink},{provide:APP_GUARD,useClass:BetaRequestGuard}],exports:[BetaPolicy,BetaErrorReporter]})export class BetaCoreModule{}
@Controller('beta')@UseInterceptors(AuthNoStore)export class BetaController{
 constructor(@Inject(BetaService)private beta:BetaService,@Inject(BetaErrorReporter)private errors:BetaErrorReporter){}
 @Post('redeem')@HttpCode(202)redeem(@Body()b:unknown){return this.beta.redeem(b);}
 @Post('errors')@HttpCode(202)@UseGuards(SessionGuard)async error(@Req()r:AuthRequest,@Body()b:unknown){const status=await this.beta.status(r.principal);if(!betaConfiguration().enabled||!['INVITED','ACTIVE_BETA','SUSPENDED_BETA'].includes(status.state))throw new ForbiddenException();return this.errors.capture({...((b&&typeof b==='object')?b:{}),code:'CLIENT_CRASH',service:'web'});}
 @Get('admission')@UseGuards(SessionGuard)admission(@Req()r:AuthRequest){return this.beta.admissions(r.principal);}
 @Get('status')@UseGuards(SessionGuard)status(@Req()r:AuthRequest){return this.beta.status(r.principal);}
 @Post('acknowledge')@UseGuards(SessionGuard)ack(@Req()r:AuthRequest,@Body()b:unknown){return this.beta.acknowledge(r.principal,b);}
 @Post('feedback')@HttpCode(202)@UseGuards(SessionGuard)feedback(@Req()r:AuthRequest,@Body()b:unknown){return this.beta.feedback(r.principal,b);}
}
@Controller('internal/beta')@UseGuards(AdminGuard)@UseInterceptors(AuthNoStore)export class BetaAdminController{
 constructor(@Inject(BetaService)private beta:BetaService){}
 @Get('dashboard')dashboard(@Req()r:AdminRequest){return this.beta.dashboard(r.admin);}
 @Get('invites')invites(@Req()r:AdminRequest){return this.beta.invites(r.admin);}
 @Post('invites')invite(@Req()r:AdminRequest,@Body()b:unknown){return this.beta.invite(r.admin,b);}
 @Post('invites/:id/revoke')revoke(@Req()r:AdminRequest,@Param('id')id:string){return this.beta.revoke(r.admin,id);}
 @Post('accounts/:id')state(@Req()r:AdminRequest,@Param('id')id:string,@Body()b:unknown){return this.beta.transition(r.admin,id,b);}
 @Post('switch')kill(@Req()r:AdminRequest,@Body()b:unknown){return this.beta.switch(r.admin,b);}
}
@Module({imports:[AuthModule,AdminModule,UploadModule],controllers:[BetaController,BetaAdminController],providers:[DatabaseService,PasswordService,BetaService],exports:[BetaService]})export class BetaModule{}
