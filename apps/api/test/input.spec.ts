import { email, password, device } from '../src/auth/input';
describe('account input', () => {
  it('normalizes case/whitespace without rewriting plus or dots', () => {
    expect(email('  First.Last+backup@Example.COM  ')).toEqual({ display: 'First.Last+backup@Example.COM', normalized: 'first.last+backup@example.com' });
    expect(email('firstlast@example.com').normalized).not.toEqual(email('first.last@example.com').normalized);
    for (const value of ['bad', 'a..b@example.com', 'a@-bad.com', 'a@example..com', '\r\na@example.com\r\nInjected']) expect(() => email(value)).toThrow();
  });
  it('accepts long Unicode and whitespace passwords exactly, with no complexity rules', () => {
    expect(password('a'.repeat(12))).toBe('a'.repeat(12));
    expect(password(' '.repeat(12))).toBe(' '.repeat(12));
    expect(password('🔒'.repeat(128))).toBe('🔒'.repeat(128));
    expect(password('x'.repeat(1024))).toHaveLength(1024);
    expect(() => password('x'.repeat(11))).toThrow();
    expect(() => password('x'.repeat(1025))).toThrow();
  });
  it('validates device metadata without treating the identifier as a credential', () => {
    expect(device({ identifier: 'test-device', displayName: 'iPhone', platform: 'ios' })?.platform).toBe('ios');
    expect(() => device({ identifier: 'test', displayName: 'device', platform: 'unknown' })).toThrow();
  });
});
