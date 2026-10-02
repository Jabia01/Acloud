// Generated data only. Requires a running built API + PostgreSQL + private storage.
import assert from 'node:assert/strict';
import { randomBytes,randomUUID,createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
process.loadEnvFile('.env');
const base=process.env.API_BASE_URL || 'http://127.0.0.1:3001';
assert.ok(['127.0.0.1','localhost'].includes(new URL(base).hostname),'Local API required');
assert.ok(['127.0.0.1','localhost'].includes(new URL(process.env.S3_ENDPOINT).hostname),'Local object storage required');
const bytes=randomBytes(512*1024),sha=data=>createHash('sha256').update(data).digest('hex');
const password=randomUUID().repeat(2),email=`upload-live-${randomUUID()}@example.invalid`;
let token,stage='setup';
const pass=value=>console.info(`PASS ${value}`);
async function api(method,path,body,extra={}) {
  stage=`${method} ${path.startsWith('/uploads/') ? '/uploads/:id' : path.startsWith('/assets/') ? '/assets/:id' : path}`;
  const response=await fetch(new URL(path,base),{method,headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`} : {}),...extra},...(body===undefined?{}:{body:JSON.stringify(body)}),signal:AbortSignal.timeout(20000),redirect:'error'});
  assert.ok(response.ok,'Unexpected API result'); const data=await response.json();
  for (const secret of [process.env.S3_SECRET_ACCESS_KEY,process.env.MINIO_ROOT_PASSWORD,password]) if (secret) assert.ok(!JSON.stringify(data).includes(secret));
  assert.ok(!/storage_object_key|password_hash|token_hash/.test(JSON.stringify(data)));
  return data;
}
try {
  await api('GET','/health');
  await api('POST','/auth/register',{email,password});
  token=(await api('POST','/auth/login',{email,password,device:{identifier:randomUUID(),displayName:'Generated upload fixture',platform:'other'}})).sessionToken;
  const input={media_type:'test',expected_size_bytes:bytes.length,checksum_sha256:sha(bytes)},key=randomUUID();
  const upload=await api('POST','/uploads',input,{'Idempotency-Key':key});
  const retry=await api('POST','/uploads',input,{'Idempotency-Key':key}); assert.equal(retry.id,upload.id);
  assert.notEqual((await api('GET',`/assets/${upload.assetId}`)).status,'PROTECTED');
  pass('authenticated creation; repeat key reuses session; asset initially unprotected');
  assert.equal((await api('POST',`/uploads/${upload.id}/start`)).status,'UPLOADING');
  stage='direct generated PUT';
  const transfer=await fetch(upload.authorization.url,{method:'PUT',headers:upload.authorization.headers,body:bytes,redirect:'error',signal:AbortSignal.timeout(20000)});
  assert.ok(transfer.ok); assert.notEqual((await api('GET',`/assets/${upload.assetId}`)).status,'PROTECTED');
  pass('512 KiB generated file sent directly to storage; transmitted bytes alone do not protect');
  let completed=await api('POST',`/uploads/${upload.id}/complete`);
  for (let attempt=0;completed.status==='VERIFYING' && attempt<10;attempt++) {
    await new Promise(resolve=>setTimeout(resolve,300)); completed=await api('POST',`/uploads/${upload.id}/complete`);
  }
  assert.equal(completed.status,'PROTECTED');
  assert.deepEqual(await api('GET',`/assets/${upload.assetId}`),{id:upload.assetId,mediaType:'test',status:'PROTECTED',sizeBytes:bytes.length});
  const duplicate=await api('POST',`/uploads/${upload.id}/complete`); assert.equal(duplicate.status,'PROTECTED');
  pass('server size/SHA-256 verification; safe PROTECTED metadata; repeat completion safe');
  let download=await api('POST',`/assets/${upload.assetId}/download`);
  stage='private storage and generated download';
  const signed=new URL(download.url); const anonymous=new URL(signed.pathname,signed.origin);
  assert.equal((await fetch(anonymous,{redirect:'error'})).status,403);
  let response=await fetch(download.url,{redirect:'error'}); assert.ok(response.ok); assert.equal(sha(Buffer.from(await response.arrayBuffer())),sha(bytes));
  pass('anonymous object access denied; version-scoped short-lived download SHA-256 matches');
  if (process.argv.includes('--restart-storage')) {
    stage='storage restart';
    execFileSync('docker',['compose','--env-file','.env','-f','infrastructure/docker/compose.yml','restart','storage'],{stdio:'ignore',windowsHide:true,timeout:60000});
    for (let attempt=0;attempt<30;attempt++) {
      try { if ((await fetch(`${process.env.S3_ENDPOINT}/minio/health/ready`)).ok) break; } catch {}
      await new Promise(resolve=>setTimeout(resolve,500));
    }
    download=await api('POST',`/assets/${upload.assetId}/download`);
    stage='post-restart integrity'; response=await fetch(download.url,{redirect:'error'});
    assert.ok(response.ok); assert.equal(sha(Buffer.from(await response.arrayBuffer())),sha(bytes));
    pass('storage restart preserved generated object/version; downloaded digest still matches');
  }
  await api('POST','/auth/logout'); token=undefined;
  pass('local generated object/account retained for inspection; issued login session revoked; no credentials logged');
} catch {
  if (token) { try { await api('POST','/auth/logout'); } catch {} }
  console.error(`Generated upload validation failed at ${stage}; sensitive details suppressed.`); process.exitCode=1;
}
