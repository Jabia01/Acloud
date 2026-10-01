import { Body, Controller, Delete, Get, HttpCode, Inject, Param, Post, Req, UnauthorizedException, UseGuards, UseInterceptors } from '@nestjs/common';
import { AuthNoStore } from './safe-errors';
import { AuthService } from './auth.service';
import { AuthRateLimit } from './rate-limit';
import { AuthRequest, SessionGuard } from './session.guard';
import * as input from './input';

@Controller()
@UseInterceptors(AuthNoStore)
export class AuthController {
  constructor(@Inject(AuthService) private readonly auth: AuthService) {}
  @Post('auth/register') @HttpCode(202) @UseGuards(AuthRateLimit)
  register(@Body() value: unknown) {
    const body = input.object(value); const email = input.email(body.email);
    return this.auth.register(email.display, email.normalized, input.password(body.password));
  }
  @Post('auth/login') @HttpCode(200) @UseGuards(AuthRateLimit)
  login(@Body() value: unknown) {
    const body = input.object(value);
    let email: string;
    let password: string;
    try {
      email = input.email(body.email).normalized;
      if (typeof body.password !== 'string' || !body.password.length || Array.from(body.password).length > 1024 || Buffer.byteLength(body.password) > 4096) throw new Error('Invalid input');
      password = body.password;
    }
    catch { throw new UnauthorizedException('Invalid credentials'); }
    return this.auth.login(email, password, input.device(body.device));
  }
  @Post('auth/logout') @HttpCode(200) @UseGuards(SessionGuard)
  logout(@Req() request: AuthRequest) { return this.auth.revokeSession(request.principal, request.principal.sessionId, 'LOGOUT'); }
  @Post('auth/email/verify') @HttpCode(200) @UseGuards(AuthRateLimit)
  verify(@Body() value: unknown) { return this.auth.consumeToken(input.token(input.object(value).token), 'verify'); }
  @Post('auth/email/resend') @HttpCode(202) @UseGuards(AuthRateLimit)
  resend(@Body() value: unknown) { return this.auth.requestToken(input.email(input.object(value).email).normalized, 'verify'); }
  @Post('auth/password/forgot') @HttpCode(202) @UseGuards(AuthRateLimit)
  forgot(@Body() value: unknown) { return this.auth.requestToken(input.email(input.object(value).email).normalized, 'reset'); }
  @Post('auth/password/reset') @HttpCode(200) @UseGuards(AuthRateLimit)
  reset(@Body() value: unknown) { const body = input.object(value); return this.auth.consumeToken(input.token(body.token), 'reset', input.password(body.password)); }
  @Get('me') @UseGuards(SessionGuard)
  me(@Req() request: AuthRequest) { return this.auth.me(request.principal); }
  @Get('sessions') @UseGuards(SessionGuard)
  sessions(@Req() request: AuthRequest) { return this.auth.sessions(request.principal); }
  @Delete('sessions') @UseGuards(SessionGuard)
  others(@Req() request: AuthRequest) { return this.auth.revokeOthers(request.principal); }
  @Delete('sessions/:id') @UseGuards(SessionGuard)
  revoke(@Req() request: AuthRequest, @Param('id') id: string) { return this.auth.revokeSession(request.principal, input.uuid(id)); }
  @Get('devices') @UseGuards(SessionGuard)
  devices(@Req() request: AuthRequest) { return this.auth.devices(request.principal); }
  @Post('devices') @HttpCode(200) @UseGuards(SessionGuard)
  registerDevice(@Req() request: AuthRequest, @Body() body: unknown) { return this.auth.registerDevice(request.principal, input.device(input.object(body))!); }
  @Delete('devices/:id') @UseGuards(SessionGuard)
  revokeDevice(@Req() request: AuthRequest, @Param('id') id: string) { return this.auth.revokeDevice(request.principal, input.uuid(id)); }
}
