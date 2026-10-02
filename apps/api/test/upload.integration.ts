import 'reflect-metadata';
import { after,before,beforeEach,describe,test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash,randomBytes,randomUUID } from 'node:crypto';
import { request as httpRequest } from 'node:http';
import { Pool } from 'pg';
import { Test } from '@nestjs/testing';
import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { GetBucketVersioningCommand,PutObjectCommand,S3Client } from '@aws-sdk/client-s3';
import { AppModule } from '../src/app.module';
import { AccountMailer,MemoryAccountMailer } from '../src/auth/mail';
import { AuthRateLimit } from '../src/auth/rate-limit';
import { SafeErrors } from '../src/auth/safe-errors';
import { ObjectStorageProvider,S3ObjectStorageProvider } from '../src/uploads/storage';

describe('real PostgreSQL + private S3 generated-file uploads',{concurrency:false},() => {
  let app: INestApplication,pool: Pool,admin: Pool,s3: S3Client,storage: S3ObjectStorageProvider;
  const originalURL=process.env.DATABASE_URL!,schema=`upload_test_${randomUUID().replaceAll('-','')}`;
  const objects: {key:string;versionId:string}[]=[];
  let token: string,userId: string,other: string,deviceId: string;
  let password: string,email: string;
  const digest=(data: Uint8Array) => createHash('sha256').update(data).digest('hex');
  const body=(data: Uint8Array) => ({media_type:'test',expected_size_bytes:data.byteLength,checksum_sha256:digest(data)});
  const post=(path: string,value: unknown={},bearer: string=token) => request(app.getHttpServer()).post(path).set('Authorization',`Bearer ${bearer}`).send(value);
  const create=(data=randomBytes(128),key=randomUUID(),bearer=token) => post('/uploads',body(data),bearer).set('Idempotency-Key',key);
  const account=async () => {
    const email=`generated-${randomUUID()}@example.invalid`,password=randomUUID().repeat(2);
    await request(app.getHttpServer()).post('/auth/register').send({email,password}).expect(202);
    const login=await request(app.getHttpServer()).post('/auth/login').send({email,password,device:{identifier:randomUUID(),displayName:'Generated fixture',platform:'other'}}).expect(200);
    return {token:login.body.sessionToken as string,userId:login.body.user.id as string,email,password};
  };
  const row=async (id: string) => (await pool.query('SELECT a.*,u.id AS upload_id FROM assets a JOIN upload_sessions u ON u.asset_id=a.id WHERE u.id=$1',[id])).rows[0];
  const remember=(key: string,versionId: string|undefined|null) => { if (versionId) objects.push({key,versionId}); };
  const put=async (upload: any,data: Uint8Array) => {
    await post(`/uploads/${upload.id}/start`).expect(200);
    const response=await fetch(upload.authorization.url,{method:'PUT',headers:upload.authorization.headers,body:Buffer.from(data),signal:AbortSignal.timeout(10000)});
    if (response.ok) { const a=await row(upload.id); remember(a.storage_object_key,response.headers.get('x-amz-version-id')); }
    return response;
  };
  const injected=async (upload: any,data: Uint8Array) => {
    const a=await row(upload.id);
    const result=await s3.send(new PutObjectCommand({Bucket:process.env.S3_BUCKET,Key:a.storage_object_key,Body:Buffer.from(data)}));
    remember(a.storage_object_key,result.VersionId);
  };
  const protectedFixture=async () => {
    const data=randomBytes(257),upload=(await create(data).expect(200)).body;
    assert.ok((await put(upload,data)).ok);
    assert.equal((await post(`/uploads/${upload.id}/complete`).expect(200)).body.status,'PROTECTED');
    return {upload,data};
  };
  before(async () => {
    assert.ok(['127.0.0.1','localhost'].includes(new URL(originalURL).hostname));
    assert.ok(['127.0.0.1','localhost'].includes(new URL(process.env.S3_ENDPOINT!).hostname));
    admin=new Pool({connectionString:originalURL}); await admin.query(`CREATE SCHEMA ${schema}`);
    const url=new URL(originalURL); url.searchParams.set('options',`-c search_path=${schema}`); process.env.DATABASE_URL=url.href;
    const {migrate}=await import('../../../scripts/migrate.mjs'); assert.equal(await migrate(),3); assert.equal(await migrate(),0);
    pool=new Pool({connectionString:url.href});
    const module=await Test.createTestingModule({imports:[AppModule]}).overrideProvider(AccountMailer).useValue(new MemoryAccountMailer()).overrideGuard(AuthRateLimit).useValue({canActivate:()=>true}).compile();
    app=module.createNestApplication(); app.useGlobalFilters(new SafeErrors()); await app.init();
    storage=app.get(ObjectStorageProvider) as S3ObjectStorageProvider;
    s3=new S3Client({endpoint:process.env.S3_ENDPOINT,region:process.env.S3_REGION||'us-east-1',forcePathStyle:true,credentials:{accessKeyId:process.env.S3_ACCESS_KEY_ID!,secretAccessKey:process.env.S3_SECRET_ACCESS_KEY!},requestChecksumCalculation:'WHEN_REQUIRED'});
    assert.equal((await s3.send(new GetBucketVersioningCommand({Bucket:process.env.S3_BUCKET}))).Status,'Enabled');
    other=(await account()).token;
  });
  beforeEach(async () => {
    const fixture=await account(); ({token,userId,email,password}=fixture);
    deviceId=(await pool.query('SELECT device_id FROM sessions WHERE user_id=$1',[userId])).rows[0].device_id;
  });
  after(async () => {
    // Explicitly remove only the generated fixture versions, never arbitrary bucket contents.
    for (const object of objects) await storage.deleteObject(object.key,object.versionId);
    s3?.destroy(); await app?.close(); await pool?.end();
    if (admin) { await admin.query(`DROP SCHEMA IF EXISTS ${schema} CASCADE`); await admin.end(); }
    process.env.DATABASE_URL=originalURL;
  });
  test('unauthenticated and invalid-auth upload creation fail',async () => {
    await request(app.getHttpServer()).post('/uploads').send(body(randomBytes(5))).set('Idempotency-Key',randomUUID()).expect(401);
    await create(randomBytes(5),randomUUID(),'invalid').expect(401);
  });
  test('device ownership is validated and revoked devices are rejected',async () => {
    const foreign=(await pool.query('SELECT id FROM devices WHERE user_id<>$1 LIMIT 1',[userId])).rows[0].id;
    await post('/uploads',{...body(randomBytes(5)),device_id:foreign}).set('Idempotency-Key',randomUUID()).expect(404);
    await pool.query('UPDATE devices SET revoked_at=now() WHERE id=$1',[deviceId]); await create().expect(401);
  });
  test('revoked session cannot create or complete upload',async () => {
    const upload=(await create().expect(200)).body;
    await post('/auth/logout').expect(200); await create().expect(401); await post(`/uploads/${upload.id}/complete`).expect(401);
  });
  test('wrong user cannot inspect, complete, cancel or authorize asset/download',async () => {
    const upload=(await create().expect(200)).body;
    await request(app.getHttpServer()).get(`/uploads/${upload.id}`).set('Authorization',`Bearer ${other}`).expect(404);
    await post(`/uploads/${upload.id}/complete`,{},other).expect(404);
    await post(`/uploads/${upload.id}/start`,{},other).expect(404);
    await request(app.getHttpServer()).delete(`/uploads/${upload.id}`).set('Authorization',`Bearer ${other}`).expect(404);
    await request(app.getHttpServer()).get(`/assets/${upload.assetId}`).set('Authorization',`Bearer ${other}`).expect(404);
    await post(`/assets/${upload.assetId}/download`,{},other).expect(404);
  });
  test('create retries/concurrent duplicates share one asset and reservation',async () => {
    const data=randomBytes(100),key=randomUUID();
    const responses=await Promise.all([create(data,key),create(data,key)]);
    responses.forEach(r=>assert.equal(r.status,200)); assert.equal(responses[0]!.body.id,responses[1]!.body.id);
    assert.equal((await pool.query('SELECT COUNT(*)::int AS n FROM assets WHERE user_id=$1',[userId])).rows[0].n,1);
    assert.equal(Number((await pool.query('SELECT reserved_bytes FROM development_entitlements WHERE user_id=$1',[userId])).rows[0].reserved_bytes),100);
    await create(randomBytes(101),key).expect(409);
  });
  test('short-lived authorization is scoped to exact key, checksum, length and PUT',async () => {
    const data=randomBytes(100),upload=(await create(data).expect(200)).body;
    const url=new URL(upload.authorization.url); assert.ok(Number(url.searchParams.get('X-Amz-Expires'))<=300);
    const altered=new URL(url); altered.pathname+='-other';
    assert.equal((await fetch(altered,{method:'PUT',headers:upload.authorization.headers,body:data})).status,403);
    // MinIO rejects missing signed PUT headers with 400 before signature-method checking.
    assert.ok([400,403].includes((await fetch(url,{method:'GET'})).status));
    const wrongHeaders={...upload.authorization.headers,'x-amz-checksum-sha256':Buffer.from('b'.repeat(64),'hex').toString('base64')};
    // Rejection may be signature mismatch (403) or checksum mismatch (400).
    assert.ok([400,403].includes((await fetch(url,{method:'PUT',headers:wrongHeaders,body:data})).status));
    const oversizedHeaders={...upload.authorization.headers,'content-length':String(data.length+1)};
    assert.ok([400,403].includes((await fetch(url,{method:'PUT',headers:oversizedHeaders,body:randomBytes(data.length+1)})).status));
  });
  test('private object cannot be accessed anonymously',async () => {
    const {upload}=await protectedFixture(); const a=await row(upload.id);
    assert.equal((await fetch(`${process.env.S3_ENDPOINT}/${process.env.S3_BUCKET}/${a.storage_object_key}`)).status,403);
  });
  test('client receipt without an object fails and cannot claim protection',async () => {
    const upload=(await create().expect(200)).body;
    await post(`/uploads/${upload.id}/complete`,{status:'PROTECTED'}).expect(400);
    const result=await post(`/uploads/${upload.id}/complete`).expect(200);
    assert.equal(result.body.status,'FAILED'); assert.equal(result.body.errorCode,'OBJECT_MISSING');
    assert.equal((await row(upload.id)).protected_at,null);
  });
  test('object with wrong size fails verification and download is denied',async () => {
    const upload=(await create(randomBytes(100)).expect(200)).body; await injected(upload,randomBytes(99));
    const result=await post(`/uploads/${upload.id}/complete`).expect(200);
    assert.equal(result.body.status,'FAILED'); assert.equal(result.body.errorCode,'SIZE_MISMATCH');
    await post(`/assets/${upload.assetId}/download`).expect(409);
  });
  test('same-size corrupted object fails SHA-256 verification',async () => {
    const upload=(await create(randomBytes(100)).expect(200)).body; await injected(upload,randomBytes(100));
    const result=await post(`/uploads/${upload.id}/complete`).expect(200);
    assert.equal(result.body.status,'FAILED'); assert.equal(result.body.errorCode,'CHECKSUM_MISMATCH');
    assert.equal((await row(upload.id)).protected_at,null);
  });
  test('successful generated-file roundtrip becomes protected only after server verification',async () => {
    const data=randomBytes(4096),upload=(await create(data).expect(200)).body;
    assert.ok((await put(upload,data)).ok); assert.equal((await row(upload.id)).status,'UPLOADING');
    await post(`/uploads/${upload.id}/complete`).expect(200).expect(r=>assert.equal(r.body.status,'PROTECTED'));
    const asset=await request(app.getHttpServer()).get(`/assets/${upload.assetId}`).set('Authorization',`Bearer ${token}`).expect(200);
    assert.deepEqual(asset.body,{id:upload.assetId,mediaType:'test',status:'PROTECTED',sizeBytes:data.length});
    const download=(await post(`/assets/${upload.assetId}/download`).expect(200)).body;
    const bytes=Buffer.from(await (await fetch(download.url)).arrayBuffer()); assert.equal(digest(bytes),digest(data));
    const ent=(await pool.query('SELECT * FROM development_entitlements WHERE user_id=$1',[userId])).rows[0];
    assert.equal(Number(ent.reserved_bytes),0); assert.equal(Number(ent.protected_bytes),data.length);
  });
  test('duplicate and concurrent complete calls are safe and quota moves once',async () => {
    const data=randomBytes(100),upload=(await create(data).expect(200)).body; assert.ok((await put(upload,data)).ok);
    const responses=await Promise.all([post(`/uploads/${upload.id}/complete`),post(`/uploads/${upload.id}/complete`)]);
    responses.forEach(r=>assert.equal(r.status,200)); await post(`/uploads/${upload.id}/complete`).expect(200);
    assert.equal((await pool.query("SELECT COUNT(*)::int AS n FROM asset_verifications WHERE asset_id=$1 AND verification_status='SUCCEEDED'",[upload.assetId])).rows[0].n,1);
    assert.equal(Number((await pool.query('SELECT protected_bytes FROM development_entitlements WHERE user_id=$1',[userId])).rows[0].protected_bytes),100);
  });
  test('quota exceeded is rejected using protected bytes and reservations',async () => {
    const data=randomBytes(100); await create(data).expect(200);
    await pool.query('UPDATE development_entitlements SET quota_bytes=150 WHERE user_id=$1',[userId]); await create(data).expect(409);
  });
  test('simultaneous quota race admits only one upload',async () => {
    await pool.query('INSERT INTO development_entitlements(user_id,quota_bytes) VALUES($1,150)',[userId]);
    const results=await Promise.all([create(randomBytes(100)),create(randomBytes(100))]);
    assert.deepEqual(results.map(r=>r.status).sort(),[200,409]);
    assert.equal(Number((await pool.query('SELECT reserved_bytes FROM development_entitlements WHERE user_id=$1',[userId])).rows[0].reserved_bytes),100);
  });
  test('expired session is not protected and reservation is released once',async () => {
    const upload=(await create().expect(200)).body;
    await pool.query("UPDATE upload_sessions SET expires_at=now()-interval '1 second' WHERE id=$1",[upload.id]);
    const result=await post(`/uploads/${upload.id}/complete`).expect(200); assert.equal(result.body.status,'EXPIRED');
    await post(`/uploads/${upload.id}/complete`).expect(200);
    assert.equal(Number((await pool.query('SELECT reserved_bytes FROM development_entitlements WHERE user_id=$1',[userId])).rows[0].reserved_bytes),0);
  });
  test('upload signed authorization actually expires at storage',async () => {
    const a=(await create(randomBytes(16)).expect(200)).body,asset=await row(a.id),data=randomBytes(16);
    const authorization=await storage.createUploadAuthorization(asset.storage_object_key,16,digest(data),1);
    await new Promise(resolve=>setTimeout(resolve,2200));
    assert.equal((await fetch(authorization.url,{method:'PUT',headers:authorization.headers,body:data})).status,403);
  });
  test('download authorization ownership, version scope and expiry',async () => {
    const {upload}=await protectedFixture(),a=await row(upload.id);
    await post(`/assets/${upload.assetId}/download`,{},other).expect(404);
    const authorization=await storage.createDownloadAuthorization(a.storage_object_key,a.storage_version_id,1);
    assert.equal(new URL(authorization.url).searchParams.get('versionId'),a.storage_version_id);
    await new Promise(resolve=>setTimeout(resolve,2200)); assert.equal((await fetch(authorization.url)).status,403);
  });
  test('conditional PUT rejects replay; protected download pins verified version',async () => {
    const {upload,data}=await protectedFixture(); assert.equal((await put(upload,data)).status,412);
    await injected(upload,randomBytes(data.length));
    const download=(await post(`/assets/${upload.assetId}/download`).expect(200)).body;
    assert.equal(digest(Buffer.from(await (await fetch(download.url)).arrayBuffer())),digest(data));
  });
  test('verification retry after missing object safely succeeds once bytes arrive',async () => {
    const data=randomBytes(100),upload=(await create(data).expect(200)).body;
    assert.equal((await post(`/uploads/${upload.id}/complete`).expect(200)).body.status,'FAILED');
    assert.ok((await put(upload,data)).ok); assert.equal((await post(`/uploads/${upload.id}/complete`).expect(200)).body.status,'PROTECTED');
    assert.equal((await pool.query('SELECT COUNT(*)::int AS n FROM asset_verifications WHERE asset_id=$1',[upload.assetId])).rows[0].n,2);
  });
  test('abandoned uploads are identifiable without automatic object deletion',async () => {
    const upload=(await create().expect(200)).body;
    await pool.query("UPDATE upload_sessions SET expires_at=now()-interval '1 hour' WHERE id=$1",[upload.id]);
    const abandoned=await pool.query("SELECT id FROM upload_sessions WHERE expires_at<now() AND status NOT IN ('PROTECTED','CANCELLED','EXPIRED') AND user_id=$1",[userId]);
    assert.ok(abandoned.rows.some(r=>r.id===upload.id)); assert.equal((await row(upload.id)).status,'QUEUED');
  });
  test('object key is opaque and API responses omit storage credentials/internals',async () => {
    const upload=(await create().expect(200)).body,a=await row(upload.id);
    assert.match(a.storage_object_key,/^objects\/[0-9a-f]{8}\/[0-9a-f-]{36}$/); assert.ok(!a.storage_object_key.includes(email));
    assert.ok(!JSON.stringify(upload).includes(process.env.S3_SECRET_ACCESS_KEY!)); assert.ok(!JSON.stringify(upload).includes(process.env.MINIO_ROOT_PASSWORD!));
    const metadata=(await request(app.getHttpServer()).get(`/assets/${upload.assetId}`).set('Authorization',`Bearer ${token}`).expect(200)).body;
    assert.deepEqual(Object.keys(metadata).sort(),['id','mediaType','sizeBytes','status']);
    await post('/uploads',{...body(randomBytes(5)),original_filename:'private.jpg'}).set('Idempotency-Key',randomUUID()).expect(400);
  });
  test('oversized/malformed payload metadata is rejected before authorization',async () => {
    for (const size of [0,-1,5*1024*1024+1]) await post('/uploads',{media_type:'test',expected_size_bytes:size,checksum_sha256:'a'.repeat(64)}).set('Idempotency-Key',randomUUID()).expect(400);
    assert.equal((await pool.query('SELECT COUNT(*)::int AS n FROM assets WHERE user_id=$1',[userId])).rows[0].n,0);
  });
  test('cancel retains reservation until signed capability expiry and retry remains safe',async () => {
    const upload=(await create().expect(200)).body;
    for (let i=0;i<2;i++) await request(app.getHttpServer()).delete(`/uploads/${upload.id}`).set('Authorization',`Bearer ${token}`).expect(200).expect(r=>assert.equal(r.body.status,'CANCELLED'));
    assert.equal((await post(`/uploads/${upload.id}/complete`).expect(200)).body.status,'CANCELLED');
    assert.equal(Number((await pool.query('SELECT reserved_bytes FROM development_entitlements WHERE user_id=$1',[userId])).rows[0].reserved_bytes),128);
    await pool.query("UPDATE upload_sessions SET expires_at=now()-interval '1 second' WHERE id=$1",[upload.id]);
    await request(app.getHttpServer()).delete(`/uploads/${upload.id}`).set('Authorization',`Bearer ${token}`).expect(200);
    assert.equal(Number((await pool.query('SELECT reserved_bytes FROM development_entitlements WHERE user_id=$1',[userId])).rows[0].reserved_bytes),0);
  });
  test('interrupted partial transfer cannot protect; safe whole-file retry recovers',async () => {
    const data=randomBytes(4096),upload=(await create(data).expect(200)).body;
    await new Promise<void>(resolve => {
      const req=httpRequest(upload.authorization.url,{method:'PUT',headers:upload.authorization.headers});
      req.on('error',()=>resolve()); req.on('response',()=>{ req.destroy(); resolve(); });
      req.write(data.subarray(0,128)); setTimeout(()=>{req.destroy();resolve();},100);
    });
    const incomplete=await post(`/uploads/${upload.id}/complete`).expect(200);
    assert.equal(incomplete.body.status,'FAILED'); assert.equal(incomplete.body.errorCode,'OBJECT_MISSING');
    assert.ok((await put(upload,data)).ok); assert.equal((await post(`/uploads/${upload.id}/complete`).expect(200)).body.status,'PROTECTED');
  });
  test('protected bytes continue counting against quota after reservation moves',async () => {
    await protectedFixture(); await pool.query('UPDATE development_entitlements SET quota_bytes=300 WHERE user_id=$1',[userId]);
    await create(randomBytes(100)).expect(409);
  });
  test('expired verifier lease can be reclaimed without duplicate quota movement',async () => {
    const data=randomBytes(128),upload=(await create(data).expect(200)).body; assert.ok((await put(upload,data)).ok);
    await pool.query("UPDATE upload_sessions SET status='VERIFYING',verification_lease=$2,verification_lease_until=now()-interval '1 second' WHERE id=$1",[upload.id,randomUUID()]);
    await pool.query("UPDATE assets SET status='VERIFYING' WHERE id=$1",[upload.assetId]);
    assert.equal((await post(`/uploads/${upload.id}/complete`).expect(200)).body.status,'PROTECTED');
    assert.equal(Number((await pool.query('SELECT protected_bytes FROM development_entitlements WHERE user_id=$1',[userId])).rows[0].protected_bytes),128);
  });
  test('signed checksum rejects malicious bytes before creating an object',async () => {
    const data=randomBytes(128),upload=(await create(data).expect(200)).body;
    assert.equal((await put(upload,randomBytes(data.length))).status,400);
    assert.equal((await post(`/uploads/${upload.id}/complete`).expect(200)).body.status,'FAILED');
  });
  test('transient verification failure is sanitized, audited and retryable',async () => {
    const data=randomBytes(128),upload=(await create(data).expect(200)).body; assert.ok((await put(upload,data)).ok);
    const original=storage.verifyObject; storage.verifyObject=async () => { throw new Error('provider-internal-sensitive-detail'); };
    try {
      const result=await post(`/uploads/${upload.id}/complete`).expect(200);
      assert.equal(result.body.errorCode,'STORAGE_UNAVAILABLE'); assert.ok(!JSON.stringify(result.body).includes('sensitive'));
    } finally { storage.verifyObject=original; }
    assert.equal((await post(`/uploads/${upload.id}/complete`).expect(200)).body.status,'PROTECTED');
  });
  test('provider success boolean alone cannot bypass integrity policy',async () => {
    const upload=(await create(randomBytes(128)).expect(200)).body;
    const original=storage.verifyObject;
    storage.verifyObject=async () => ({ok:true,sizeBytes:127,checksum:'a'.repeat(64),versionId:'fixture-version'});
    try {
      const result=await post(`/uploads/${upload.id}/complete`).expect(200);
      assert.equal(result.body.status,'FAILED'); assert.equal(result.body.errorCode,'SIZE_MISMATCH'); assert.equal((await row(upload.id)).protected_at,null);
    } finally { storage.verifyObject=original; }
  });
  test('start records transfer intent idempotently without granting protection',async () => {
    const upload=(await create().expect(200)).body;
    assert.equal((await row(upload.id)).status,'QUEUED');
    for (let i=0;i<2;i++) assert.equal((await post(`/uploads/${upload.id}/start`).expect(200)).body.status,'UPLOADING');
    assert.equal((await row(upload.id)).protected_at,null);
    await post('/auth/logout').expect(200); await post(`/uploads/${upload.id}/start`).expect(401);
  });
  test('cancellation during verification invalidates the lease and prevents late protection',async () => {
    const data=randomBytes(128),upload=(await create(data).expect(200)).body; assert.ok((await put(upload,data)).ok);
    let entered!:()=>void,release!:()=>void;
    const started=new Promise<void>(resolve=>{entered=resolve;}),gate=new Promise<void>(resolve=>{release=resolve;});
    const original=storage.verifyObject;
    storage.verifyObject=async (...args) => { const result=await original.apply(storage,args); entered(); await gate; return result; };
    const completion=post(`/uploads/${upload.id}/complete`).then(r=>r);
    try {
      await started; assert.equal((await row(upload.id)).status,'VERIFYING');
      await request(app.getHttpServer()).delete(`/uploads/${upload.id}`).set('Authorization',`Bearer ${token}`).expect(200);
      release(); const response=await completion; assert.equal(response.status,200); assert.equal(response.body.status,'CANCELLED');
      assert.equal((await row(upload.id)).protected_at,null);
      assert.equal(Number((await pool.query('SELECT protected_bytes FROM development_entitlements WHERE user_id=$1',[userId])).rows[0].protected_bytes),0);
    } finally { release(); storage.verifyObject=original; await completion; }
  });
  test('revocation during verification prevents commit and a fresh authenticated retry recovers',async () => {
    const data=randomBytes(128),upload=(await create(data).expect(200)).body; assert.ok((await put(upload,data)).ok);
    let entered!:()=>void,release!:()=>void;
    const started=new Promise<void>(resolve=>{entered=resolve;}),gate=new Promise<void>(resolve=>{release=resolve;});
    const original=storage.verifyObject;
    storage.verifyObject=async (...args) => { const result=await original.apply(storage,args); entered(); await gate; return result; };
    const completion=post(`/uploads/${upload.id}/complete`).then(r=>r);
    try {
      await started; await post('/auth/logout').expect(200); release(); assert.equal((await completion).status,401);
      assert.equal((await row(upload.id)).protected_at,null);
    } finally { release(); storage.verifyObject=original; await completion; }
    token=(await request(app.getHttpServer()).post('/auth/login').send({email,password}).expect(200)).body.sessionToken;
    await pool.query("UPDATE upload_sessions SET verification_lease_until=now()-interval '1 second' WHERE id=$1",[upload.id]);
    assert.equal((await post(`/uploads/${upload.id}/complete`).expect(200)).body.status,'PROTECTED');
  });
});
