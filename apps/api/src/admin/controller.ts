import {BadRequestException,Body,Controller,Get,Headers,HttpCode,Inject,Param,Post,Query,Req,UseGuards,UseInterceptors} from '@nestjs/common';
import {AuthNoStore} from '../auth/safe-errors';
import {uuid} from '../auth/input';
import {AdminService} from './service';
import {AdminGuard,AdminRateLimit,AdminRequest} from './guard';
@Controller('internal') @UseInterceptors(AuthNoStore)
export class AdminController {
 constructor(@Inject(AdminService)private readonly service:AdminService){}
 @Post('login') @HttpCode(200) @UseGuards(AdminRateLimit)
 login(@Body() value:unknown){return this.service.login(value);}
 @Post('auth/challenge') @HttpCode(200) @UseGuards(AdminRateLimit)
 challenge(@Body()value:unknown){return this.service.challenge(value);}
 @Get('me') @UseGuards(AdminGuard,AdminRateLimit)
 me(@Req() r:AdminRequest){return this.service.me(r.admin);}
 @Post('logout') @HttpCode(200) @UseGuards(AdminGuard,AdminRateLimit)
 logout(@Req() r:AdminRequest){return this.service.logout(r.admin);}
 @Get('overview') @UseGuards(AdminGuard,AdminRateLimit)
 overview(@Req() r:AdminRequest){return this.service.overview(r.admin);}
 @Get('storage') @UseGuards(AdminGuard,AdminRateLimit)
 storage(@Req() r:AdminRequest){return this.service.overview(r.admin);}
 @Get('system') @UseGuards(AdminGuard,AdminRateLimit)
 system(@Req() r:AdminRequest){return this.service.system(r.admin);}
 @Get('security') @UseGuards(AdminGuard,AdminRateLimit)
 security(@Req() r:AdminRequest){return this.service.security(r.admin);}
 @Get('users') @UseGuards(AdminGuard,AdminRateLimit)
 users(@Req() r:AdminRequest,@Query() q:Record<string,unknown>){return this.service.users(r.admin,q);}
 @Get('users/:id') @UseGuards(AdminGuard,AdminRateLimit)
 user(@Req() r:AdminRequest,@Param('id') id:string){return this.service.user(r.admin,uuid(id));}
 @Post('users/:id/status') @HttpCode(200) @UseGuards(AdminGuard,AdminRateLimit)
 status(@Req() r:AdminRequest,@Param('id') id:string,@Body() b:unknown,@Headers('idempotency-key') key:string){return this.service.account(r.admin,uuid(id),b,key);}
 @Post('users/:id/quota') @HttpCode(200) @UseGuards(AdminGuard,AdminRateLimit)
 quota(@Req() r:AdminRequest,@Param('id') id:string,@Body() b:unknown,@Headers('idempotency-key') key:string){return this.service.quota(r.admin,uuid(id),b,key);}
 @Post('users/:id/sessions/revoke') @HttpCode(200) @UseGuards(AdminGuard,AdminRateLimit)
 sessions(@Req() r:AdminRequest,@Param('id') id:string,@Body() b:unknown,@Headers('idempotency-key') key:string){return this.service.revoke(r.admin,uuid(id),'sessions',uuid(id),b,key);}
 @Post('users/:id/:kind/:target/revoke') @HttpCode(200) @UseGuards(AdminGuard,AdminRateLimit)
 revoke(@Req() r:AdminRequest,@Param('id') id:string,@Param('kind') kind:string,@Param('target') target:string,@Body() b:unknown,@Headers('idempotency-key') key:string){if(!['sessions','devices'].includes(kind))throw new BadRequestException('Invalid operation');return this.service.revoke(r.admin,uuid(id),kind==='sessions'?'session':'device',uuid(target),b,key);}
 @Get('uploads') @UseGuards(AdminGuard,AdminRateLimit)
 uploads(@Req() r:AdminRequest,@Query() q:Record<string,unknown>){return this.service.list(r.admin,'uploads',q);}
 @Post('uploads/:id/:action') @HttpCode(200) @UseGuards(AdminGuard,AdminRateLimit)
 uploadAction(@Req() r:AdminRequest,@Param('id') id:string,@Param('action') action:string,@Body() b:unknown,@Headers('idempotency-key') key:string){if(!['retry','abort'].includes(action))throw new BadRequestException('Invalid operation');return this.service.enqueue(r.admin,uuid(id),b,key,action==='abort'?'ABORT':'VERIFY');}
 @Get('devices') @UseGuards(AdminGuard,AdminRateLimit)
 devices(@Req() r:AdminRequest,@Query() q:Record<string,unknown>){return this.service.list(r.admin,'devices',q);}
 @Get('audit') @UseGuards(AdminGuard,AdminRateLimit)
 audit(@Req() r:AdminRequest,@Query() q:Record<string,unknown>){return this.service.list(r.admin,'audit',q);}
 @Get('admins') @UseGuards(AdminGuard,AdminRateLimit)
 admins(@Req() r:AdminRequest,@Query() q:Record<string,unknown>){return this.service.list(r.admin,'admins',q);}
 @Post('admins') @HttpCode(200) @UseGuards(AdminGuard,AdminRateLimit)
 create(@Req() r:AdminRequest,@Body() b:unknown,@Headers('idempotency-key') key:string){return this.service.createAdmin(r.admin,b,key);}
 @Post('admins/:id') @HttpCode(200) @UseGuards(AdminGuard,AdminRateLimit)
 manage(@Req() r:AdminRequest,@Param('id') id:string,@Body() b:unknown,@Headers('idempotency-key') key:string){return this.service.manageAdmin(r.admin,uuid(id),b,key);}
}
