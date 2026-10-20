import {storageConfig,storageBinding,type StorageConfig} from './storage-config';
import { Injectable, Logger } from '@nestjs/common';
import { createHash } from 'node:crypto';
import { ListObjectVersionsCommand, AbortMultipartUploadCommand, CompleteMultipartUploadCommand, CreateMultipartUploadCommand, ListPartsCommand, UploadPartCommand, DeleteObjectCommand, GetBucketAclCommand, GetBucketVersioningCommand, GetObjectCommand, HeadObjectCommand, PutObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';

export interface UploadAuthorization { method: 'PUT'; url: string; headers: Record<string,string>; expiresAt: string }
export interface DownloadAuthorization { method: 'GET'; url: string; expiresAt: string }
export interface ObjectMetadata { sizeBytes: number; versionId: string }
export type VerificationCode = 'OBJECT_MISSING' | 'SIZE_MISMATCH' | 'CHECKSUM_MISMATCH' | 'STORAGE_UNAVAILABLE' | 'IMMUTABILITY_UNAVAILABLE';
export type VerificationResult = { ok: true; sizeBytes: number; checksum: string; versionId: string } | { ok: false; code: VerificationCode; sizeBytes?: number; checksum?: string };
export interface StoredPart { partNumber: number; sizeBytes: number; etag: string; checksum?: string }
export abstract class ObjectStorageProvider {
  identity(){return {provider:'minio',binding:null as string|null,environment:'test'};}
  assertBinding(provider:string,binding:string|null){const current=this.identity();if(current.provider!==provider||binding!==null&&current.binding!==binding||binding===null&&provider!=='minio')throw new Error('Storage binding mismatch');}
  async health(){return{provider:this.identity().provider,environment:this.identity().environment,status:await this.isHealthy()?'healthy':'degraded'};}
  async isHealthy():Promise<boolean>{return false;}
  async beginMultipart(_key: string): Promise<string> { throw new Error("Unsupported storage provider"); }
  async authorizePart(_key: string,_upload: string,_number: number,_size: number,_checksum: string,_ttl: number): Promise<UploadAuthorization> { throw new Error("Unsupported storage provider"); }
  async listParts(_key: string,_upload: string): Promise<StoredPart[]> { throw new Error("Unsupported storage provider"); }
  async completeMultipart(_key: string,_upload: string,_parts: StoredPart[]): Promise<string> { throw new Error("Unsupported storage provider"); }
  async abortMultipart(_key: string,_upload: string): Promise<void> { throw new Error("Unsupported storage provider"); }
  abstract createUploadAuthorization(key: string, size: number, checksum: string, ttlSeconds: number): Promise<UploadAuthorization>;
  abstract getObjectMetadata(key: string, versionId?: string): Promise<ObjectMetadata>;
  abstract verifyObject(key: string, expectedSize: number, expectedChecksum: string, versionId?: string): Promise<VerificationResult>;
  abstract createDownloadAuthorization(key: string, versionId: string, ttlSeconds: number): Promise<DownloadAuthorization>;
  // No public deletion route. Callers must supply separately audited explicit authorization.
  async versionsForDeletion(_key:string):Promise<string[]>{throw new Error('Version inventory unavailable');}
  abstract deleteObject(key: string, versionId: string): Promise<void>;
}
function endpoint(value: string): string {
  const url = new URL(value);
  if (url.username || url.password || url.search || url.hash || url.pathname !== '/') throw new Error('Invalid storage configuration');
  const local = (['localhost','127.0.0.1','storage'].includes(url.hostname) || url.hostname.endsWith('.local'));
  if (url.protocol !== 'https:' && !(url.protocol === 'http:' && local && process.env.NODE_ENV !== 'production')) throw new Error('Invalid storage configuration');
  return url.origin;
}
@Injectable()
export class S3ObjectStorageProvider extends ObjectStorageProvider {
  private readonly clients=new Map<string,S3Client>();
  private readonly logger=new Logger(S3ObjectStorageProvider.name);
  onModuleDestroy(){for(const client of this.clients.values())client.destroy();this.clients.clear();}
  protected releaseClient(client:S3Client){if(![...this.clients.values()].includes(client))client.destroy();}
  constructor(protected readonly config?:StorageConfig){super();}
  identity(){return this.config?{provider:this.config.provider,binding:storageBinding(this.config),environment:this.config.environment}:super.identity();}
  protected get bucket(){return this.config?.bucket??process.env.S3_BUCKET;}
  protected get b2(){return this.config?.provider==='backblaze_b2';}
  protected async ensurePrivate(_client:S3Client){}
  protected async send(client:S3Client,command:any,options:any={}){
    const started=performance.now();let outcome='error';
    try{const result=await client.send(command,{abortSignal:AbortSignal.timeout(30000),...options});outcome='ok';return result as any;}
    finally{this.logger.debug({code:'STORAGE_OPERATION',operation:command.constructor.name,durationMs:Math.round(performance.now()-started),outcome});}
  }
  async isHealthy():Promise<boolean>{const c=this.client();try{await this.ensurePrivate(c);return(await c.send(new GetBucketVersioningCommand({Bucket:this.bucket}),{abortSignal:AbortSignal.timeout(5000)})).Status==='Enabled';}catch{return false;}finally{this.releaseClient(c);}}
  protected client(publicEndpoint = false,maxAttempts=3) {
    if(this.config){const key=`${publicEndpoint}:${maxAttempts}`,existing=this.clients.get(key);if(existing)return existing;const client=new S3Client({endpoint:publicEndpoint?this.config.publicEndpoint:this.config.endpoint,region:this.config.region,forcePathStyle:true,maxAttempts,credentials:{accessKeyId:this.config.keyId,secretAccessKey:this.config.secret},requestChecksumCalculation:'WHEN_REQUIRED',responseChecksumValidation:'WHEN_REQUIRED'});this.clients.set(key,client);return client;}
    if (!process.env.S3_ACCESS_KEY_ID || !process.env.S3_SECRET_ACCESS_KEY || !process.env.S3_BUCKET) throw new Error('Storage configuration unavailable');
    return new S3Client({ endpoint:endpoint((publicEndpoint ? process.env.S3_PUBLIC_ENDPOINT : undefined) || process.env.S3_ENDPOINT || ''),
      region:process.env.S3_REGION || 'us-east-1', forcePathStyle:true, maxAttempts:2,
      credentials:{accessKeyId:process.env.S3_ACCESS_KEY_ID,secretAccessKey:process.env.S3_SECRET_ACCESS_KEY},
      requestChecksumCalculation:'WHEN_REQUIRED',responseChecksumValidation:'WHEN_REQUIRED' });
  }
  async beginMultipart(key: string): Promise<string> {
    const client=this.client(false,1); try {
      await this.ensurePrivate(client);
      const r=await this.send(client,new CreateMultipartUploadCommand({Bucket:this.bucket,Key:key,ContentType:'application/octet-stream'}));
      if(!r.UploadId) throw new Error('Multipart unavailable'); return r.UploadId;
    } finally { this.releaseClient(client); }
  }
  async authorizePart(key: string,upload: string,number: number,size: number,checksum: string,ttl: number): Promise<UploadAuthorization> {
    if(!Number.isInteger(number)||number<1||number>10000||!upload||!Number.isSafeInteger(size)||size<=0||!Number.isInteger(ttl)||ttl<1||ttl>300||!/^[a-f0-9]{64}$/.test(checksum))throw new Error('Invalid part authorization');
    const client=this.client(true); try {
      await this.ensurePrivate(client);
      const digest=Buffer.from(checksum,'hex').toString('base64');
      const url=await getSignedUrl(client,new UploadPartCommand({Bucket:this.bucket,Key:key,UploadId:upload,PartNumber:number,ContentLength:size,...(this.b2?{}:{ChecksumSHA256:digest})}),
        {expiresIn:ttl,signableHeaders:new Set(['content-length','x-amz-checksum-sha256']),unhoistableHeaders:new Set(['x-amz-checksum-sha256'])});
      return {method:'PUT',url,headers:{'content-length':String(size),...(this.b2?{}:{'x-amz-checksum-sha256':digest})},expiresAt:new Date(Date.now()+ttl*1000).toISOString()};
    } finally { this.releaseClient(client); }
  }
  async listParts(key: string,upload: string): Promise<StoredPart[]> {
    const client=this.client(); const parts:StoredPart[]=[]; let marker:string|undefined;
    try { await this.ensurePrivate(client); do {
      const r=await this.send(client,new ListPartsCommand({Bucket:this.bucket,Key:key,UploadId:upload,PartNumberMarker:marker,MaxParts:1000}));
      for(const p of r.Parts ?? []) { if(!p.PartNumber || !p.ETag || !Number.isSafeInteger(p.Size)) throw new Error('Invalid storage part');
        parts.push({partNumber:p.PartNumber,sizeBytes:p.Size!,etag:p.ETag,checksum:p.ChecksumSHA256}); }
      if(parts.length>10000) throw new Error('Too many parts'); if(r.IsTruncated&&(!r.NextPartNumberMarker||r.NextPartNumberMarker===marker))throw new Error('Invalid storage pagination'); marker=r.IsTruncated ? r.NextPartNumberMarker : undefined;
    } while(marker); return parts; } finally { this.releaseClient(client); }
  }
  async completeMultipart(key: string,upload: string,parts: StoredPart[]): Promise<string> {
    const client=this.client(); try {
      await this.ensurePrivate(client);
      const r=await this.send(client,new CompleteMultipartUploadCommand({Bucket:this.bucket,Key:key,UploadId:upload,...(this.b2?{}:{IfNoneMatch:'*'}),MultipartUpload:{Parts:parts.map(p=>({PartNumber:p.partNumber,ETag:p.etag}))}}));
      if(!r.VersionId || r.VersionId==='null') throw new Error('Immutable version required'); return r.VersionId;
    } finally { this.releaseClient(client); }
  }
  async abortMultipart(key: string,upload: string): Promise<void> {
    const client=this.client(); try { await this.ensurePrivate(client); await this.send(client,new AbortMultipartUploadCommand({Bucket:this.bucket,Key:key,UploadId:upload})); }
    finally { this.releaseClient(client); }
  }
  async createUploadAuthorization(key: string, size: number, checksum: string, ttlSeconds: number): Promise<UploadAuthorization> {
    if(!Number.isInteger(ttlSeconds)||ttlSeconds<1||ttlSeconds>300||!Number.isSafeInteger(size)||size<=0||!/^[a-f0-9]{64}$/.test(checksum))throw new Error('Invalid upload authorization');
    const client = this.client(true);
    try {
      await this.ensurePrivate(client);
      const checksumBase64 = Buffer.from(checksum,'hex').toString('base64');
      const command = new PutObjectCommand({Bucket:this.bucket,Key:key,ContentLength:size,ContentType:'application/octet-stream',...(this.b2?{}:{ChecksumSHA256:checksumBase64,IfNoneMatch:'*'})});
      const url = await getSignedUrl(client,command,{expiresIn:ttlSeconds,
        signableHeaders:new Set(['content-length','content-type','if-none-match','x-amz-checksum-sha256']),
        unhoistableHeaders:new Set(['x-amz-checksum-sha256'])});
      return {method:'PUT',url,headers:{'content-type':'application/octet-stream','content-length':String(size),...(this.b2?{}:{'if-none-match':'*','x-amz-checksum-sha256':checksumBase64})},expiresAt:new Date(Date.now()+ttlSeconds*1000).toISOString()};
    } finally { this.releaseClient(client); }
  }
  async versionsForDeletion(key:string):Promise<string[]>{
    if(!/^objects\/[a-f0-9]{8}\/[a-f0-9-]{36}$/.test(key))throw new Error('Invalid owned object');
    const client=this.client();try{await this.ensurePrivate(client);const versions:string[]=[];let keyMarker:string|undefined,versionMarker:string|undefined;
      for(let page=0;page<20;page++){const r=await this.send(client,new ListObjectVersionsCommand({Bucket:this.bucket,Prefix:key,KeyMarker:keyMarker,VersionIdMarker:versionMarker,MaxKeys:500}),{abortSignal:AbortSignal.timeout(10000)});
        for(const v of [...r.Versions??[],...r.DeleteMarkers??[]])if(v.Key===key){if(!v.VersionId||v.VersionId==='null')throw new Error('Unsafe version');versions.push(v.VersionId);}
        if(!r.IsTruncated)return [...new Set(versions)];if(!r.NextKeyMarker||r.NextKeyMarker===keyMarker&&r.NextVersionIdMarker===versionMarker)throw new Error('Invalid inventory cursor');keyMarker=r.NextKeyMarker;versionMarker=r.NextVersionIdMarker;
      }throw new Error('Version inventory bound exceeded');
    }finally{this.releaseClient(client);}
  }
  async getObjectMetadata(key: string, versionId?: string): Promise<ObjectMetadata> {
    const client = this.client();
    try {
      await this.ensurePrivate(client);
      const result = await this.send(client,new HeadObjectCommand({Bucket:this.bucket,Key:key,VersionId:versionId}),{abortSignal:AbortSignal.timeout(10000)});
      if (versionId&&result.VersionId!==versionId || !result.VersionId || result.VersionId === 'null' || !Number.isSafeInteger(result.ContentLength)) throw new Error('Immutable object metadata unavailable');
      return {sizeBytes:result.ContentLength!,versionId:result.VersionId};
    } finally { this.releaseClient(client); }
  }
  async verifyObject(key: string, expectedSize: number, expectedChecksum: string, versionId?: string): Promise<VerificationResult> {
    const client = this.client(),started=performance.now();
    try {
      await this.ensurePrivate(client);
      // Version pinning protects verified content even if a privileged writer later overwrites the key.
      const versioning = await this.send(client,new GetBucketVersioningCommand({Bucket:this.bucket}),{abortSignal:AbortSignal.timeout(10000)});
      if (versioning.Status !== 'Enabled') return {ok:false,code:'IMMUTABILITY_UNAVAILABLE'};
      const head = await this.send(client,new HeadObjectCommand({Bucket:this.bucket,Key:key,VersionId:versionId}),{abortSignal:AbortSignal.timeout(10000)});
      if (versionId&&head.VersionId!==versionId || !head.VersionId || head.VersionId === 'null') return {ok:false,code:'IMMUTABILITY_UNAVAILABLE'};
      if (head.ContentLength !== expectedSize) return {ok:false,code:'SIZE_MISMATCH',sizeBytes:head.ContentLength};
      const object = await this.send(client,new GetObjectCommand({Bucket:this.bucket,Key:key,VersionId:head.VersionId}),{abortSignal:AbortSignal.timeout(15*60*1000)});
      if(object.VersionId!==head.VersionId)return {ok:false,code:'IMMUTABILITY_UNAVAILABLE'};
      if (!object.Body) return {ok:false,code:'OBJECT_MISSING'};
      const digest = createHash('sha256'); let bytes = 0;
      // Stream the object with bounded memory; never buffer whole objects or rely on ETag.
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
    } finally { this.logger.debug({code:'STORAGE_VERIFICATION_DURATION',durationMs:Math.round(performance.now()-started)});this.releaseClient(client); }
  }
  async createDownloadAuthorization(key: string, versionId: string, ttlSeconds: number): Promise<DownloadAuthorization> {
    if(!versionId||versionId==='null'||!Number.isInteger(ttlSeconds)||ttlSeconds<1||ttlSeconds>60)throw new Error('Invalid download authorization');
    const client = this.client(true);
    try {
      await this.ensurePrivate(client);
      const url = await getSignedUrl(client,new GetObjectCommand({Bucket:this.bucket,Key:key,VersionId:versionId,ResponseContentDisposition:'attachment; filename="download.bin"',ResponseContentType:'application/octet-stream'}),{expiresIn:ttlSeconds});
      return {method:'GET',url,expiresAt:new Date(Date.now()+ttlSeconds*1000).toISOString()};
    } finally { this.releaseClient(client); }
  }
  async deleteObject(key: string, versionId: string): Promise<void> {
    if(!versionId||versionId==='null')throw new Error('Immutable version required');
    const client = this.client();
    try { await this.ensurePrivate(client); await this.send(client,new DeleteObjectCommand({Bucket:this.bucket,Key:key,VersionId:versionId}),{abortSignal:AbortSignal.timeout(10000)}); }
    finally { this.releaseClient(client); }
  }
}

export class MinioStorageProvider extends S3ObjectStorageProvider{constructor(config=storageConfig()){if(config.provider!=='minio')throw new Error('Invalid MinIO configuration');super(config);}}
export class BackblazeB2StorageProvider extends S3ObjectStorageProvider{
 constructor(config=storageConfig()){if(config.provider!=='backblaze_b2')throw new Error('Invalid B2 configuration');super(config);}
 protected async ensurePrivate(client:S3Client){const acl=await this.send(client,new GetBucketAclCommand({Bucket:this.bucket}),{abortSignal:AbortSignal.timeout(5000)});if(!acl.Owner?.ID||!acl.Grants?.length||acl.Grants.some((g:any)=>g.Grantee?.URI||g.Grantee?.ID!==acl.Owner.ID))throw new Error('Private bucket required');}
}
export function createStorageProvider(){const c=storageConfig();return c.provider==='backblaze_b2'?new BackblazeB2StorageProvider(c):new MinioStorageProvider(c);}
