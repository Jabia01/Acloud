import { CanActivate, ExecutionContext, HttpException, Inject, Injectable, Optional } from '@nestjs/common';
import { createHash, randomUUID } from 'node:crypto';
import {DatabaseService} from '../database.service';
import type { Request } from 'express';

@Injectable()
export class AuthRateLimit implements CanActivate {
  constructor(@Optional() @Inject(DatabaseService) private readonly db?:DatabaseService) {}
  private blocked(){void this.db?.query("INSERT INTO operational_security_events(id,code) VALUES($1,'CUSTOMER_RATE_LIMIT')",[randomUUID()]).catch(()=>{});throw new HttpException('Too many requests',429);}
  private readonly buckets = new Map<string, { count: number; end: number }>();
  private consume(key: string, limit: number, now: number) {
    let bucket = this.buckets.get(key);
    if (!bucket || bucket.end <= now) {
      if (this.buckets.size >= 10000) {
        for (const [entry, value] of this.buckets) if (value.end <= now) this.buckets.delete(entry);
        if (this.buckets.size >= 10000) this.blocked();
      }
      bucket = { count: 0, end: now + 10 * 60 * 1000 }; this.buckets.set(key, bucket);
    }
    if (++bucket.count > limit) this.blocked();
  }
  canActivate(context: ExecutionContext): boolean {
    const request = context.switchToHttp().getRequest<Request>();
    const action = context.getHandler().name;
    const limit = action === 'login' ? 30 : 10;
    const now = Date.now();
    this.consume(`${action}:ip:${request.ip || 'unknown'}`, limit, now);
    if (typeof request.body?.email === 'string') {
      const identity = createHash('sha256').update(request.body.email.trim().toLowerCase()).digest('hex');
      this.consume(`${action}:account:${identity}`, action === 'login' ? 15 : 5, now);
    }
    return true;
  }
}
