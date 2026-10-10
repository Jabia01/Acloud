import {Module,Controller,UseGuards,UseInterceptors,Get,Post,Req,Body,HttpCode,Inject} from '@nestjs/common';
import {AuthModule} from '../auth/auth.module';import {SessionGuard,type AuthRequest} from '../auth/session.guard';import {AuthNoStore} from '../auth/safe-errors';import {DatabaseService} from '../database.service';import {UploadModule} from '../uploads/upload.module';import {LocalStorageService} from './service';
@Controller('storage/free-up-space') @UseGuards(SessionGuard) @UseInterceptors(AuthNoStore)
export class LocalStorageController{
 constructor(@Inject(LocalStorageService)private service:LocalStorageService){}
 @Get('policy')policy(@Req()r:AuthRequest){return this.service.policy(r.principal);}
 @Post('eligibility') @HttpCode(200)eligibility(@Req()r:AuthRequest,@Body()b:unknown){return this.service.eligibility(r.principal,b);}
 @Post('prepare') @HttpCode(200)prepare(@Req()r:AuthRequest,@Body()b:unknown){return this.service.prepare(r.principal,b);}
 @Post('consume') @HttpCode(200)consume(@Req()r:AuthRequest,@Body()b:unknown){return this.service.consume(r.principal,b);}
 @Post('confirm-result') @HttpCode(200)result(@Req()r:AuthRequest,@Body()b:unknown){return this.service.result(r.principal,b);}
}
@Module({imports:[AuthModule,UploadModule],controllers:[LocalStorageController],providers:[DatabaseService,LocalStorageService]})export class LocalStorageModule{}
