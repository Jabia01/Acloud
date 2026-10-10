import { ArgumentsHost, Catch, ExceptionFilter, HttpException, Injectable, NestInterceptor, ExecutionContext, CallHandler } from '@nestjs/common';
import type {BetaErrorReporter} from '../beta/errors';
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
  constructor(private reporter?:BetaErrorReporter){}
  catch(error: unknown, host: ArgumentsHost) {
    const response = host.switchToHttp().getResponse<Response>();
    const oversized=(error as {type?:string})?.type==='entity.too.large';
    const status = oversized?413:error instanceof HttpException ? error.getStatus() : 503;
    if(status>=500&&this.reporter)void this.reporter.capture({code:'API_FAILURE',service:'api'}).catch(()=>{});
    const message = oversized?'Request too large':error instanceof HttpException && status < 500 ? error.message : 'Service unavailable';
    response.setHeader('Cache-Control', 'no-store');
    if (status === 429) response.setHeader('Retry-After', '600');
    response.status(status).json({ message });
  }
}
