import { PasswordService } from '../src/auth/password.service';
import { randomUUID } from 'node:crypto';
describe('Argon2id passwords', () => {
  const service = new PasswordService();
  beforeAll(async () => { await service.onModuleInit(); });
  it('hashes with production-strength Argon2id, randomized salts and correct verification', async () => {
    const password = randomUUID().repeat(4);
    const hash = await service.hash(password);
    expect(hash).toMatch(/^\$argon2id\$v=19\$/);
    expect(hash.split('$')[3]?.split(',').sort()).toEqual(['m=65536', 'p=1', 't=3']);
    expect(hash).not.toContain(password);
    expect(await service.hash(password)).not.toBe(hash);
    expect(await service.verify(hash, password)).toBe(true);
    expect(await service.verify(hash, password + '!')).toBe(false);
    expect(await service.verify(undefined, password)).toBe(false);
  });
  it('bounds concurrent hashing work and rejects excessive queued work', async () => {
    const results = await Promise.allSettled(Array.from({ length: 19 }, () => service.hash(randomUUID())));
    expect(results.filter(result => result.status === 'fulfilled')).toHaveLength(18);
    expect(results.filter(result => result.status === 'rejected')).toHaveLength(1);
  }, 15000);
});
