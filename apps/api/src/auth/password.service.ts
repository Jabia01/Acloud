import { Injectable, OnModuleInit, ServiceUnavailableException } from '@nestjs/common';
import * as argon2 from 'argon2';
import { randomBytes } from 'node:crypto';

@Injectable()
export class PasswordService implements OnModuleInit {
  private dummyHash = '';
  private active = 0;
  private readonly waiting: (() => void)[] = [];
  private async budget<T>(operation: () => Promise<T>): Promise<T> {
    // Bound memory consumed by Argon2 even if attackers rotate IPs/accounts.
    if (this.active >= 2) {
      if (this.waiting.length >= 16) throw new ServiceUnavailableException('Authentication busy');
      await new Promise<void>(resolve => this.waiting.push(resolve));
    } else this.active++;
    try { return await operation(); }
    finally {
      const next = this.waiting.shift();
      if (next) next(); else this.active--;
    }
  }
  async onModuleInit() { this.dummyHash = await this.hash(randomBytes(32).toString('hex')); }
  hash(value: string) {
    return this.budget(() => argon2.hash(value, { type: argon2.argon2id, memoryCost: 65536, timeCost: 3, parallelism: 1, hashLength: 32 }));
  }
  async verify(hash: string | undefined, value: string): Promise<boolean> {
    return this.budget(async () => { try {
      const valid = await argon2.verify(hash || this.dummyHash, value);
      return Boolean(hash) && valid;
    } catch { return false; } });
  }
}
