import type { ExecutionContext } from '@nestjs/common';
import { AuthRateLimit } from '../src/auth/rate-limit';
function context(action: string, ip: string, email = 'fixture@example.invalid') {
  return { getHandler: () => ({ name: action }), switchToHttp: () => ({ getRequest: () => ({ ip, body: { email } }) }) } as unknown as ExecutionContext;
}
describe('abuse controls', () => {
  it.each(['login', 'register', 'forgot', 'resend'])('limits %s by account and IP and resets after expiry', action => {
    const limiter = new AuthRateLimit();
    const now = jest.spyOn(Date, 'now').mockReturnValue(0);
    const limit = action === 'login' ? 15 : 5;
    for (let attempt = 0; attempt < limit; attempt++) expect(limiter.canActivate(context(action, '127.0.0.1'))).toBe(true);
    expect(() => limiter.canActivate(context(action, '127.0.0.1'))).toThrow('Too many requests');
    now.mockReturnValue(600001);
    expect(limiter.canActivate(context(action, '127.0.0.1'))).toBe(true);
    now.mockRestore();
  });
  it('limits requests even when attackers change email each time', () => {
    const limiter = new AuthRateLimit();
    for (let attempt = 0; attempt < 10; attempt++) limiter.canActivate(context('register', '127.0.0.1', `a${attempt}@example.invalid`));
    expect(() => limiter.canActivate(context('register', '127.0.0.1', 'fresh@example.invalid'))).toThrow();
  });
});
