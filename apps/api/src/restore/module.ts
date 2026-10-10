import {Module,Controller,Get,Post,Req,Param,Body,Inject,UseGuards,UseInterceptors,HttpCode} from '@nestjs/common';import {DatabaseService} from '../database.service';import {UploadModule} from '../uploads/upload.module';import {AuthModule} from '../auth/auth.module';import {SessionGuard,type AuthRequest} from '../auth/session.guard';import {AuthNoStore} from '../auth/safe-errors';import {uuid} from '../auth/input';import {RestoreService} from './service';
@Controller('restore')@UseGuards(SessionGuard)@UseInterceptors(AuthNoStore)export class RestoreController{
 constructor(@Inject(RestoreService)private restore:RestoreService){}
 @Get('status')status(@Req()r:AuthRequest){return this.restore.status(r.principal);}
 @Get('assets/:id')evidence(@Req()r:AuthRequest,@Param('id')id:string){return this.restore.evidence(r.principal,uuid(id));}
 @Post('assets/:id/authorize')@HttpCode(200)authorize(@Req()r:AuthRequest,@Param('id')id:string,@Body()b:unknown){return this.restore.authorize(r.principal,uuid(id),b);}
 @Post('assets/:id/recheck')@HttpCode(200)recheck(@Req()r:AuthRequest,@Param('id')id:string,@Body()b:unknown){return this.restore.recheck(r.principal,uuid(id),b);}
 @Post('events')@HttpCode(202)event(@Req()r:AuthRequest,@Body()b:unknown){return this.restore.event(r.principal,b);}
}
@Module({imports:[AuthModule,UploadModule],controllers:[RestoreController],providers:[DatabaseService,RestoreService],exports:[RestoreService]})export class RestoreModule{}
