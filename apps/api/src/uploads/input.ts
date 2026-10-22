import { BadRequestException } from '@nestjs/common';
import { createHash } from 'node:crypto';
import { uuid } from '../auth/input';
export interface UploadInput { mediaType: 'image'|'video'|'test'; size: number; checksum: string; deviceId: string|null; libraryId?: string|null; multipart: boolean; requestHash: string }
export function setting(name: string, fallback: number, maximum: number): number {
  const value = Number(process.env[name] ?? fallback);
  if (!Number.isSafeInteger(value) || value <= 0 || value > maximum) throw new Error('Invalid upload configuration');
  return value;
}
export const maxUploadBytes = () => setting('UPLOAD_MAX_BYTES',5*1024*1024,5*1024*1024);
export const maxMultipartBytes = () => setting('MULTIPART_MAX_BYTES',1024*1024*1024,10*1024*1024*1024);
export const partSize = () => { const n=setting('MULTIPART_PART_BYTES',8*1024*1024,64*1024*1024); if(n<5*1024*1024) throw new Error('Part size too small'); return n; };
export const sessionTTL = () => setting('MULTIPART_SESSION_SECONDS',7*24*3600,7*24*3600);
export const maximumUploadAuthorizationSeconds=300;
export const uploadTTL = () => setting('UPLOAD_TTL_SECONDS',maximumUploadAuthorizationSeconds,maximumUploadAuthorizationSeconds);
export const downloadTTL = () => setting('DOWNLOAD_TTL_SECONDS',60,60);
export const defaultQuota = () => setting('FREE_DEV_QUOTA_BYTES',20*1024*1024,Number.MAX_SAFE_INTEGER);
export function uploadInput(value: unknown): UploadInput {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new BadRequestException('Invalid upload request');
  const b = value as Record<string,unknown>;
  // Reject filenames, object keys, protection state and arbitrary provider options.
  if (Object.keys(b).some(k => !['media_type','expected_size_bytes','checksum_sha256','device_id','multipart','library_id'].includes(k))) throw new BadRequestException('Invalid upload request');
  if (!['image','video','test'].includes(String(b.media_type)) || typeof b.media_type !== 'string' ||
      !Number.isSafeInteger(b.expected_size_bytes) || Number(b.expected_size_bytes) <= 0 || Number(b.expected_size_bytes) > (b.multipart === true ? maxMultipartBytes() : maxUploadBytes()) ||
      typeof b.checksum_sha256 !== 'string' || !/^[a-f0-9]{64}$/.test(b.checksum_sha256)) throw new BadRequestException('Invalid upload request');
  if (b.multipart !== undefined && typeof b.multipart !== 'boolean') throw new BadRequestException('Invalid upload request');
  const mediaType = b.media_type as UploadInput['mediaType'];
  const size = Number(b.expected_size_bytes); const checksum = b.checksum_sha256;
  const deviceId = b.device_id === undefined || b.device_id === null ? null : uuid(b.device_id);
  const libraryId=b.library_id===undefined?null:uuid(b.library_id);
  const multipart=b.multipart === true;
  return {mediaType,size,checksum,deviceId,libraryId,multipart,requestHash:createHash('sha256').update(JSON.stringify(libraryId ? [mediaType,size,checksum,deviceId,multipart,libraryId] : multipart ? [mediaType,size,checksum,deviceId,'multipart'] : [mediaType,size,checksum,deviceId])).digest('hex')};
}
