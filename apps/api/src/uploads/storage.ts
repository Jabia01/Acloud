import { Injectable } from '@nestjs/common';
import { createHash } from 'node:crypto';
import { DeleteObjectCommand, GetBucketVersioningCommand, GetObjectCommand, HeadObjectCommand, PutObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';

export interface UploadAuthorization { method: 'PUT'; url: string; headers: Record<string,string>; expiresAt: string }
export interface DownloadAuthorization { method: 'GET'; url: string; expiresAt: string }
export interface ObjectMetadata { sizeBytes: number; versionId: string }
export type VerificationCode = 'OBJECT_MISSING' | 'SIZE_MISMATCH' | 'CHECKSUM_MISMATCH' | 'STORAGE_UNAVAILABLE' | 'IMMUTABILITY_UNAVAILABLE';
export type VerificationResult = { ok: true; sizeBytes: number; checksum: string; versionId: string } | { ok: false; code: VerificationCode; sizeBytes?: number; checksum?: string };
export abstract class ObjectStorageProvider {
  abstract createUploadAuthorization(key: string, size: number, checksum: string, ttlSeconds: number): Promise<UploadAuthorization>;
  abstract getObjectMetadata(key: string, versionId?: string): Promise<ObjectMetadata>;
  abstract verifyObject(key: string, expectedSize: number, expectedChecksum: string): Promise<VerificationResult>;
  abstract createDownloadAuthorization(key: string, versionId: string, ttlSeconds: number): Promise<DownloadAuthorization>;
  // No public deletion route. Callers must supply separately audited explicit authorization.
  abstract deleteObject(key: string, versionId: string): Promise<void>;
}
function endpoint(value: string): string {
  const url = new URL(value);
  if (url.username || url.password || url.search || url.hash || url.pathname !== '/') throw new Error('Invalid storage configuration');
  const local = ['localhost','127.0.0.1','storage'].includes(url.hostname);
  if (url.protocol !== 'https:' && !(url.protocol === 'http:' && local && process.env.NODE_ENV !== 'production')) throw new Error('Invalid storage configuration');
  return url.origin;
}
@Injectable()
export class S3ObjectStorageProvider extends ObjectStorageProvider {
  private client(publicEndpoint = false) {
    if (!process.env.S3_ACCESS_KEY_ID || !process.env.S3_SECRET_ACCESS_KEY || !process.env.S3_BUCKET) throw new Error('Storage configuration unavailable');
    return new S3Client({ endpoint:endpoint((publicEndpoint ? process.env.S3_PUBLIC_ENDPOINT : undefined) || process.env.S3_ENDPOINT || ''),
      region:process.env.S3_REGION || 'us-east-1', forcePathStyle:true, maxAttempts:2,
      credentials:{accessKeyId:process.env.S3_ACCESS_KEY_ID,secretAccessKey:process.env.S3_SECRET_ACCESS_KEY},
      requestChecksumCalculation:'WHEN_REQUIRED',responseChecksumValidation:'WHEN_REQUIRED' });
  }
  async createUploadAuthorization(key: string, size: number, checksum: string, ttlSeconds: number): Promise<UploadAuthorization> {
    const client = this.client(true);
    try {
      const checksumBase64 = Buffer.from(checksum,'hex').toString('base64');
      const command = new PutObjectCommand({Bucket:process.env.S3_BUCKET,Key:key,ContentLength:size,ContentType:'application/octet-stream',ChecksumSHA256:checksumBase64,IfNoneMatch:'*'});
      const url = await getSignedUrl(client,command,{expiresIn:ttlSeconds,
        signableHeaders:new Set(['content-length','content-type','if-none-match','x-amz-checksum-sha256']),
        unhoistableHeaders:new Set(['x-amz-checksum-sha256'])});
      return {method:'PUT',url,headers:{'content-type':'application/octet-stream','content-length':String(size),'if-none-match':'*','x-amz-checksum-sha256':checksumBase64},expiresAt:new Date(Date.now()+ttlSeconds*1000).toISOString()};
    } finally { client.destroy(); }
  }
  async getObjectMetadata(key: string, versionId?: string): Promise<ObjectMetadata> {
    const client = this.client();
    try {
      const result = await client.send(new HeadObjectCommand({Bucket:process.env.S3_BUCKET,Key:key,VersionId:versionId}),{abortSignal:AbortSignal.timeout(10000)});
      if (!result.VersionId || result.VersionId === 'null' || !Number.isSafeInteger(result.ContentLength)) throw new Error('Immutable object metadata unavailable');
      return {sizeBytes:result.ContentLength!,versionId:result.VersionId};
    } finally { client.destroy(); }
  }
  async verifyObject(key: string, expectedSize: number, expectedChecksum: string): Promise<VerificationResult> {
    const client = this.client();
    try {
      // Version pinning protects verified content even if a privileged writer later overwrites the key.
      const versioning = await client.send(new GetBucketVersioningCommand({Bucket:process.env.S3_BUCKET}),{abortSignal:AbortSignal.timeout(10000)});
      if (versioning.Status !== 'Enabled') return {ok:false,code:'IMMUTABILITY_UNAVAILABLE'};
      const head = await client.send(new HeadObjectCommand({Bucket:process.env.S3_BUCKET,Key:key}),{abortSignal:AbortSignal.timeout(10000)});
      if (!head.VersionId || head.VersionId === 'null') return {ok:false,code:'IMMUTABILITY_UNAVAILABLE'};
      if (head.ContentLength !== expectedSize) return {ok:false,code:'SIZE_MISMATCH',sizeBytes:head.ContentLength};
      const object = await client.send(new GetObjectCommand({Bucket:process.env.S3_BUCKET,Key:key,VersionId:head.VersionId}),{abortSignal:AbortSignal.timeout(15000)});
      if (!object.Body) return {ok:false,code:'OBJECT_MISSING'};
      const digest = createHash('sha256'); let bytes = 0;
      // Stream only the capped development payload; never buffer whole objects or rely on ETag.
      for await (const chunk of object.Body as AsyncIterable<Uint8Array>) {
        bytes += chunk.byteLength;
        if (bytes > expectedSize) return {ok:false,code:'SIZE_MISMATCH',sizeBytes:bytes};
        digest.update(chunk);
      }
      if (bytes !== expectedSize) return {ok:false,code:'SIZE_MISMATCH',sizeBytes:bytes};
      const checksum = digest.digest('hex');
      if (checksum !== expectedChecksum) return {ok:false,code:'CHECKSUM_MISMATCH',sizeBytes:bytes,checksum};
      return {ok:true,sizeBytes:bytes,checksum,versionId:head.VersionId};
    } catch (error: any) {
      return {ok:false,code:error?.$metadata?.httpStatusCode === 404 ? 'OBJECT_MISSING' : 'STORAGE_UNAVAILABLE'};
    } finally { client.destroy(); }
  }
  async createDownloadAuthorization(key: string, versionId: string, ttlSeconds: number): Promise<DownloadAuthorization> {
    const client = this.client(true);
    try {
      const url = await getSignedUrl(client,new GetObjectCommand({Bucket:process.env.S3_BUCKET,Key:key,VersionId:versionId,ResponseContentDisposition:'attachment; filename="download.bin"',ResponseContentType:'application/octet-stream'}),{expiresIn:ttlSeconds});
      return {method:'GET',url,expiresAt:new Date(Date.now()+ttlSeconds*1000).toISOString()};
    } finally { client.destroy(); }
  }
  async deleteObject(key: string, versionId: string): Promise<void> {
    const client = this.client();
    try { await client.send(new DeleteObjectCommand({Bucket:process.env.S3_BUCKET,Key:key,VersionId:versionId}),{abortSignal:AbortSignal.timeout(10000)}); }
    finally { client.destroy(); }
  }
}
