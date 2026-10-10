import { Body, Controller, Delete, Get, Headers, HttpCode, Inject, Param, Post, Query, Req, UseGuards, UseInterceptors, BadRequestException } from '@nestjs/common';
import { SessionGuard, type AuthRequest } from '../auth/session.guard';
import { uuid } from '../auth/input';
import { AuthNoStore } from '../auth/safe-errors';
import { uploadInput } from './input';
import { UploadService } from './upload.service';
@Controller()
@UseGuards(SessionGuard)
@UseInterceptors(AuthNoStore)
export class UploadController {
  constructor(@Inject(UploadService) private readonly uploads: UploadService) {}
  @Post('uploads') @HttpCode(200)
  create(@Req() r: AuthRequest,@Body() body: unknown,@Headers('idempotency-key') key: unknown) { return this.uploads.create(r.principal,uploadInput(body),uuid(key)); }
  @Get('uploads/:id')
  status(@Req() r: AuthRequest,@Param('id') id: string) { return this.uploads.getUpload(r.principal,uuid(id)); }
  @Post('uploads/:id/complete') @HttpCode(200)
  complete(@Req() r: AuthRequest,@Param('id') id: string,@Body() body: unknown) {
    if (body && (typeof body!=='object' || Array.isArray(body) || Object.keys(body).length)) throw new BadRequestException('Completion accepts no client protection metadata');
    return this.uploads.complete(r.principal,uuid(id));
  }
  @Post('uploads/:id/start') @HttpCode(200)
  start(@Req() r: AuthRequest,@Param('id') id: string) { return this.uploads.start(r.principal,uuid(id)); }
  @Delete('uploads/:id') @HttpCode(200)
  cancel(@Req() r: AuthRequest,@Param('id') id: string) { return this.uploads.cancel(r.principal,uuid(id)); }
  @Post('uploads/:id/multipart') @HttpCode(200)
  multipart(@Req() r: AuthRequest,@Param('id') id: string) { return this.uploads.multipartStart(r.principal,uuid(id)); }
  @Get('uploads/:id/parts')
  parts(@Req() r: AuthRequest,@Param('id') id: string) { return this.uploads.parts(r.principal,uuid(id)); }
  @Post('uploads/:id/parts/:number/authorize') @HttpCode(200)
  authorize(@Req() r: AuthRequest,@Param('id') id: string,@Param('number') number: string,@Body() body: unknown) {
    if(!/^[1-9][0-9]{0,3}$/.test(number)) throw new BadRequestException('Invalid part');
    return this.uploads.authorizePart(r.principal,uuid(id),Number(number),body);
  }
  @Post('uploads/:id/complete-multipart') @HttpCode(200)
  finishMultipart(@Req() r: AuthRequest,@Param('id') id: string,@Body() body: unknown) {
    if(body && (typeof body!=='object' || Array.isArray(body) || Object.keys(body).length)) throw new BadRequestException('Completion accepts no client metadata');
    return this.uploads.completeMultipart(r.principal,uuid(id));
  }
  @Get('assets')
  inventory(@Req() r: AuthRequest,@Query() query: Record<string,unknown>) { return this.uploads.inventory(r.principal,query); }
  @Get('storage/summary')
  storageSummary(@Req() r: AuthRequest) { return this.uploads.summary(r.principal,'storage'); }
  @Get('backup/summary')
  backupSummary(@Req() r: AuthRequest) { return this.uploads.summary(r.principal,'backup'); }
  @Get('assets/:id/integrity')
  integrity(@Req()r:AuthRequest,@Param('id')id:string){return this.uploads.integrity(r.principal,uuid(id));}
  @Get('assets/:id')
  asset(@Req() r: AuthRequest,@Param('id') id: string) { return this.uploads.asset(r.principal,uuid(id)); }
  @Post('assets/:id/download') @HttpCode(200)
  download(@Req() r: AuthRequest,@Param('id') id: string,@Body() body: unknown) {
    if(body!==undefined && (!body || typeof body!=='object' || Array.isArray(body) || Object.keys(body).length)) throw new BadRequestException('Download accepts no client metadata');
    return this.uploads.download(r.principal,uuid(id));
  }
}
