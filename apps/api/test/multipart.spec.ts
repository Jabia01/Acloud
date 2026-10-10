import { randomUUID, createHash } from 'node:crypto';
import { uploadInput, partSize, sessionTTL, uploadTTL } from '../src/uploads/input';
import { S3ObjectStorageProvider } from '../src/uploads/storage';
import { UploadService } from '../src/uploads/upload.service';

describe('multipart security boundaries',()=>{
 const env={...process.env};afterEach(()=>{process.env={...env};});
 const valid={media_type:'test',expected_size_bytes:20*1024*1024,checksum_sha256:'a'.repeat(64),multipart:true};
 test('large files require explicit multipart mode',()=>{
  expect(uploadInput(valid).multipart).toBe(true);expect(()=>uploadInput({...valid,multipart:false})).toThrow();
  for(const multipart of ['true',1,null]) expect(()=>uploadInput({...valid,multipart})).toThrow();
 });
 test('multipart caps byte size and rejects object key injection',()=>{
  for(const expected_size_bytes of [0,-1,10*1024*1024*1024+1,1.2]) expect(()=>uploadInput({...valid,expected_size_bytes})).toThrow();
  for(const key of ['storage_object_key','multipart_upload_id','part_size','status','url','filename']) expect(()=>uploadInput({...valid,[key]:'untrusted'})).toThrow();
 });
 test('part size is configurable within S3 bounds',()=>{
  expect(partSize()).toBe(8*1024*1024);process.env.MULTIPART_PART_BYTES='5242880';expect(partSize()).toBe(5*1024*1024);
  for(const n of ['1','5242879','67108865','NaN']){process.env.MULTIPART_PART_BYTES=n;expect(()=>partSize()).toThrow();}
 });
 test('session lifetime is separate from short-lived capabilities',()=>{
  expect(sessionTTL()).toBe(604800);expect(uploadTTL()).toBeLessThanOrEqual(300);
  process.env.MULTIPART_SESSION_SECONDS='604801';expect(()=>sessionTTL()).toThrow();
 });
 test('multipart mode changes idempotency fingerprint',()=>{
  const b={...valid,expected_size_bytes:100};expect(uploadInput(b).requestHash).not.toBe(uploadInput({...b,multipart:false}).requestHash);
 });
 test('legacy single-file idempotency fingerprints remain compatible across upgrade',()=>{
  const input={media_type:'test',expected_size_bytes:100,checksum_sha256:'a'.repeat(64)};
  const old=createHash('sha256').update(JSON.stringify(['test',100,'a'.repeat(64),null])).digest('hex');
  expect(uploadInput(input).requestHash).toBe(old);expect(uploadInput({...input,multipart:false}).requestHash).toBe(old);
 });
 test('part authorization signs number, upload ID, exact size and SHA256',async()=>{
  process.env.S3_ENDPOINT='http://127.0.0.1:9000';process.env.S3_BUCKET='fixture';process.env.S3_ACCESS_KEY_ID='fixture-access';process.env.S3_SECRET_ACCESS_KEY=randomUUID();
  const a=await new S3ObjectStorageProvider().authorizePart('objects/fixture/random','opaque-multipart',2,5242880,'a'.repeat(64),60);
  const url=new URL(a.url);expect(url.searchParams.get('partNumber')).toBe('2');expect(url.searchParams.get('uploadId')).toBe('opaque-multipart');expect(url.searchParams.get('X-Amz-Expires')).toBe('60');
  const signed=url.searchParams.get('X-Amz-SignedHeaders')!.split(';');expect(signed).toContain('content-length');expect(signed).toContain('x-amz-checksum-sha256');
  expect(a.headers['content-length']).toBe('5242880');expect(JSON.stringify(a)).not.toContain(process.env.S3_SECRET_ACCESS_KEY);
 });
 test('malformed part requests are rejected before database/storage access',async()=>{
  const db={transaction:jest.fn()},storage={authorizePart:jest.fn()},service=new UploadService(db as any,storage as any);
  for(const body of [null,[],{}, {size_bytes:5,checksum_sha256:'a'.repeat(64),storage_object_key:'injected'}, {size_bytes:5,checksum_sha256:'MD5'}])
   await expect(service.authorizePart({userId:randomUUID(),sessionId:randomUUID(),deviceId:null},randomUUID(),1,body)).rejects.toThrow();
  expect(db.transaction).not.toHaveBeenCalled();expect(storage.authorizePart).not.toHaveBeenCalled();
 });
});
