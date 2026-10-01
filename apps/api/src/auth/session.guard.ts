import { CanActivate, ExecutionContext, Inject, Injectable, UnauthorizedException } from '@nestjs/common';
import type { Request } from 'express';
import { AuthService, Principal } from './auth.service';
export type AuthRequest = Request & { principal: Principal };
@Injectable()
export class SessionGuard implements CanActivate {
  constructor(@Inject(AuthService) private readonly auth: AuthService) {}
  async canActivate(context: ExecutionContext) {
    const request = context.switchToHttp().getRequest<AuthRequest>();
    const header = request.headers.authorization;
    if (!header || !/^Bearer [A-Za-z0-9_-]{43}$/.test(header)) throw new UnauthorizedException('Authentication required');
    request.principal = await this.auth.authenticate(header.slice(7));
    return true;
  }
}
