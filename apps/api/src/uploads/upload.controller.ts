import { Body, Controller, Delete, Get, Headers, HttpCode, Inject, Param, Post, Req, UseGuards, UseInterceptors, BadRequestException } from '@nestjs/common';
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
  @Get('assets/:id')
  asset(@Req() r: AuthRequest,@Param('id') id: string) { return this.uploads.asset(r.principal,uuid(id)); }
  @Post('assets/:id/download') @HttpCode(200)
  download(@Req() r: AuthRequest,@Param('id') id: string) { return this.uploads.download(r.principal,uuid(id)); }
}
