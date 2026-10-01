import { BadRequestException } from '@nestjs/common';

export function object(value: unknown): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) throw new BadRequestException('Invalid input');
  return value as Record<string, unknown>;
}
export function text(value: unknown, max: number, label = 'input'): string {
  if (typeof value !== 'string' || !value.length || value.length > max || /[\u0000-\u001f\u007f]/.test(value)) throw new BadRequestException(`Invalid ${label}`);
  return value;
}
export function email(value: unknown): { display: string; normalized: string } {
  if (typeof value !== 'string') throw new BadRequestException('Invalid email');
  const display = value.trim();
  // ASCII addresses only in this foundation. Both local part and domain are
  // case-insensitive for account identity; no dot/plus/provider rewrites.
  if (display.length > 254 || !/^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$/.test(display)) throw new BadRequestException('Invalid email');
  const [local, domain] = display.split('@');
  if (!local || local.length > 64 || local.startsWith('.') || local.endsWith('.') || local.includes('..') || !domain || domain.includes('..') || domain.split('.').some(label => label.length > 63 || label.startsWith('-') || label.endsWith('-'))) throw new BadRequestException('Invalid email');
  return { display, normalized: display.toLowerCase() };
}
export function password(value: unknown): string {
  if (typeof value !== 'string' || Array.from(value).length < 12 || Array.from(value).length > 1024 || Buffer.byteLength(value, 'utf8') > 4096) throw new BadRequestException('Password must contain 12–1024 characters (at most 4096 UTF-8 bytes)');
  return value; // Preserve whitespace and Unicode; never normalize or truncate.
}
export function token(value: unknown): string {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(value)) throw new BadRequestException('Invalid or expired token');
  return value;
}
export function uuid(value: unknown): string {
  if (typeof value !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)) throw new BadRequestException('Invalid identifier');
  return value;
}
export interface DeviceInput { identifier: string; displayName: string; platform: 'ios' | 'web' | 'other'; appVersion: string | null; osVersion: string | null }
export function device(value: unknown): DeviceInput | null {
  if (value === undefined) return null;
  const input = object(value);
  const platform = text(input.platform, 10);
  if (!['ios', 'web', 'other'].includes(platform)) throw new BadRequestException('Invalid platform');
  return { identifier: text(input.identifier, 128, 'device identifier'), displayName: text(input.displayName, 100, 'device name'), platform: platform as DeviceInput['platform'], appVersion: input.appVersion == null ? null : text(input.appVersion, 40), osVersion: input.osVersion == null ? null : text(input.osVersion, 80) };
}
