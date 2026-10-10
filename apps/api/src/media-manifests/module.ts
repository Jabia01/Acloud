import {Module,Controller,Get,Post,Req,Param,Body,Query,Inject,UseGuards,UseInterceptors,HttpCode} from '@nestjs/common';
import {DatabaseService} from '../database.service';import {AuthModule} from '../auth/auth.module';import {UploadModule} from '../uploads/upload.module';import {RestoreModule} from '../restore/module';import {SessionGuard,type AuthRequest} from '../auth/session.guard';import {AuthNoStore} from '../auth/safe-errors';import {uuid} from '../auth/input';import {MediaManifestService} from './service';
@Controller('media-manifests')@UseGuards(SessionGuard)@UseInterceptors(AuthNoStore)export class MediaManifestController{
 constructor(@Inject(MediaManifestService)private manifests:MediaManifestService){}
 @Post()create(@Req()r:AuthRequest,@Body()b:unknown){return this.manifests.create(r.principal,b);}
 @Get()list(@Req()r:AuthRequest,@Query()q:Record<string,unknown>){return this.manifests.list(r.principal,q);}
 @Get('for-asset/:id')forAsset(@Req()r:AuthRequest,@Param('id')id:string){return this.manifests.forAsset(r.principal,uuid(id));}
 @Get(':id')get(@Req()r:AuthRequest,@Param('id')id:string){return this.manifests.get(r.principal,uuid(id));}
 @Get(':id/status')status(@Req()r:AuthRequest,@Param('id')id:string){return this.manifests.get(r.principal,uuid(id));}
 @Post(':id/source-changed')invalidate(@Req()r:AuthRequest,@Param('id')id:string,@Body()b:unknown){return this.manifests.invalidate(r.principal,uuid(id),b);}
 @Post(':id/resources/:resource/capture')capture(@Req()r:AuthRequest,@Param('id')id:string,@Param('resource')resource:string,@Body()b:unknown){return this.manifests.capture(r.principal,uuid(id),uuid(resource),b);}
 @Post(':id/resources/:resource/upload')upload(@Req()r:AuthRequest,@Param('id')id:string,@Param('resource')resource:string,@Body()b:unknown){return this.manifests.upload(r.principal,uuid(id),uuid(resource),b);}
 @Post(':id/resources/:resource/download')@HttpCode(200)download(@Req()r:AuthRequest,@Param('id')id:string,@Param('resource')resource:string){return this.manifests.download(r.principal,uuid(id),uuid(resource));}
 @Post(':id/resources/:resource/restore-authorization')@HttpCode(200)authorize(@Req()r:AuthRequest,@Param('id')id:string,@Param('resource')resource:string,@Body()b:unknown){return this.manifests.restoreAuthorization(r.principal,uuid(id),uuid(resource),b);}
 @Post(':id/restore-plan')@HttpCode(200)restore(@Req()r:AuthRequest,@Param('id')id:string,@Body()b:unknown){return this.manifests.restorePlan(r.principal,uuid(id),b);}
}
@Module({imports:[AuthModule,UploadModule,RestoreModule],controllers:[MediaManifestController],providers:[DatabaseService,MediaManifestService],exports:[MediaManifestService]})export class MediaManifestModule{}
