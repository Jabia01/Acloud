import { ArgumentsHost, Catch, ExceptionFilter, HttpException, Injectable, NestInterceptor, ExecutionContext, CallHandler } from '@nestjs/common';
import type { Response } from 'express';

@Injectable()
export class AuthNoStore implements NestInterceptor {
  intercept(context: ExecutionContext, next: CallHandler) {
    const response = context.switchToHttp().getResponse<Response>();
    response.setHeader('Cache-Control', 'no-store');
    response.setHeader('Referrer-Policy', 'no-referrer');
    return next.handle();
  }
}

@Catch()
export class SafeErrors implements ExceptionFilter {
  catch(error: unknown, host: ArgumentsHost) {
    const response = host.switchToHttp().getResponse<Response>();
    const status = error instanceof HttpException ? error.getStatus() : 503;
    const message = error instanceof HttpException && status < 500 ? error.message : 'Service unavailable';
    response.setHeader('Cache-Control', 'no-store');
    if (status === 429) response.setHeader('Retry-After', '600');
    response.status(status).json({ message });
  }
}
