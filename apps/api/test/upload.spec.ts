import { randomUUID } from 'node:crypto';
import { uploadInput, uploadTTL, downloadTTL } from '../src/uploads/input';
import { S3ObjectStorageProvider } from '../src/uploads/storage';
describe('upload boundary and signed authorization',() => {
  const env={...process.env};
  afterAll(() => { process.env=env; });
  const valid={media_type:'test',expected_size_bytes:32,checksum_sha256:'a'.repeat(64)};
  test('requires positive bounded bytes and a strong digest',() => {
    expect(uploadInput(valid).size).toBe(32);
    for (const expected_size_bytes of [0,-1,5*1024*1024+1,1.5,NaN,'32',null]) expect(() => uploadInput({...valid,expected_size_bytes})).toThrow();
    for (const checksum_sha256 of ['',null,'etag-md5','A'.repeat(64)]) expect(() => uploadInput({...valid,checksum_sha256})).toThrow();
  });
  test('rejects filenames, provider keys, protection claims and unknown fields',() => {
    for (const key of ['status','protected_at','storage_object_key','original_filename','url']) expect(() => uploadInput({...valid,[key]:'untrusted'})).toThrow();
  });
  test('stable request fingerprint changes with relevant metadata',() => {
    expect(uploadInput({...valid,device_id:null}).requestHash).toBe(uploadInput(valid).requestHash);
    expect(uploadInput({...valid,expected_size_bytes:33}).requestHash).not.toBe(uploadInput(valid).requestHash);
    expect(uploadInput({...valid,device_id:randomUUID()}).deviceId).toBeTruthy();
  });
  test('TTL settings cannot exceed short-lived limits',() => {
    process.env.UPLOAD_TTL_SECONDS='301'; expect(() => uploadTTL()).toThrow(); delete process.env.UPLOAD_TTL_SECONDS;
    process.env.DOWNLOAD_TTL_SECONDS='61'; expect(() => downloadTTL()).toThrow(); delete process.env.DOWNLOAD_TTL_SECONDS;
  });
  test('signs exact PUT key, length, checksum and create-only precondition',async () => {
    process.env.S3_ENDPOINT='http://127.0.0.1:9000'; process.env.S3_BUCKET='fixture-bucket';
    process.env.S3_ACCESS_KEY_ID='test-access'; process.env.S3_SECRET_ACCESS_KEY=randomUUID();
    const storage=new S3ObjectStorageProvider();
    const authorization=await storage.createUploadAuthorization(`objects/random/${randomUUID()}`,32,'a'.repeat(64),30);
    const url=new URL(authorization.url); const signed=url.searchParams.get('X-Amz-SignedHeaders')!;
    for (const name of ['content-length','content-type','if-none-match','x-amz-checksum-sha256']) expect(signed.split(';')).toContain(name);
    expect(url.searchParams.get('X-Amz-Expires')).toBe('30'); expect(authorization.headers['if-none-match']).toBe('*');
    expect(JSON.stringify(authorization)).not.toContain(process.env.S3_SECRET_ACCESS_KEY);
  });
});
