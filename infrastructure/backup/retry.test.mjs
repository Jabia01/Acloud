import {test} from 'node:test';import assert from 'node:assert/strict';
import {retry,delay} from './retry.mjs';import {BackupStore,digest} from './b2.mjs';
const options={random:()=>0,now:()=>0};
const error=status=>Object.assign(Error('B2_HTTP_'+status),{status});
const configured=(fetcher,waits=[])=>{const s=new BackupStore({bucketId:'generated-bucket'},{fetch:fetcher,wait:async n=>waits.push(n),...options});s.api={apiUrl:'https://api.backblazeb2.com',downloadUrl:'https://download.backblazeb2.com'};s.auth={authorizationToken:'test_secret'};return s;};
test('temporary failures retry at bounded exponential intervals and exhaustion preserves error',async()=>{
 const waits=[];let calls=0;const failure=error(503);
 await assert.rejects(retry(async()=>{calls++;throw failure;},{wait:async n=>waits.push(n),...options}),e=>e===failure);
 assert.equal(calls,5);assert.deepEqual(waits,[1000,2000,4000,8000]);
});
test('credential, scope, TLS and integrity failures are not retried',async()=>{
 for(const failure of [error(400),error(401),error(403),error(404),Error('UPLOAD_BINDING'),Error('DOWNLOAD_HASH'),Object.assign(TypeError('fetch failed'),{cause:{code:'CERT_HAS_EXPIRED'}})]){
  let calls=0;await assert.rejects(retry(async()=>{calls++;throw failure;},{wait:async()=>assert.fail('Must not wait'),...options}));assert.equal(calls,1);
 }
});
test('retry-after and transport timeouts remain bounded',async()=>{
 assert.equal(delay(0,'3',{...options,now:0}),3000);assert.equal(delay(0,'Thu, 01 Jan 1970 00:00:04 GMT',{...options,now:0}),4000);
 assert.equal(delay(0,'invalid',{...options,now:0}),1000);assert.equal(delay(0,'999999',{...options,now:0}),null);
 let calls=0;assert.equal(await retry(async()=>{if(calls++===0)throw Object.assign(TypeError('fetch failed'),{cause:{code:'ECONNRESET'}});return 'ok';},{wait:async()=>{},...options}),'ok');
});
test('safe B2 metadata retries 503 and honors retry-after',async()=>{
 let calls=0;const waits=[],store=configured(async()=>++calls===1?new Response('',{status:503,headers:{'Retry-After':'2'}}):Response.json({files:[]}),waits);
 assert.deepEqual(await store.call('b2_list_file_versions',{}),{files:[]});assert.equal(calls,2);assert.deepEqual(waits,[2000]);
});
test('upload retry reacquires URL/token and preserves exact encrypted bytes, name and checksum',async()=>{
 const bytes=Buffer.from('generated encrypted fixture'),name='database/2026-10-19T00-00-00.000Z/application.pgdump.enc';let urls=0,uploads=0;const waits=[];
 const store=configured(async(url,request)=>{
  if(url.endsWith('/b2_get_upload_url'))return Response.json({uploadUrl:'https://upload.backblazeb2.com/generated/'+(++urls),authorizationToken:'test_secret'});
  uploads++;assert.equal(url,'https://upload.backblazeb2.com/generated/'+uploads);assert.equal(request.body,bytes);assert.equal(request.headers['X-Bz-File-Name'],encodeURIComponent(name));assert.equal(request.headers['X-Bz-Content-Sha1'],digest(bytes,'sha1'));assert.equal(request.headers['X-Bz-Server-Side-Encryption'],'AES256');assert.equal(request.redirect,'error');
  if(uploads===1)return new Response('',{status:503});
  return Response.json({bucketId:'generated-bucket',fileName:name,fileId:'generated-version',contentLength:bytes.length,contentSha1:digest(bytes,'sha1')});
 },waits);
 const result=await store.put(name,bytes);assert.equal(result.sha256,digest(bytes));assert.equal(result.fileId,'generated-version');assert.equal(urls,2);assert.equal(uploads,2);assert.deepEqual(waits,[1000]);
});
test('failed upload validation and expired-version deletion are never automatically replayed',async()=>{
 let uploads=0;const store=configured(async url=>{
  if(url.endsWith('/b2_get_upload_url'))return Response.json({uploadUrl:'https://upload.backblazeb2.com/generated',authorizationToken:'test_secret'});
  uploads++;return Response.json({bucketId:'wrong'});
 });
 await assert.rejects(store.put('database/2026-10-19T00-00-00.000Z/application.pgdump.enc',Buffer.from('generated')),/UPLOAD_BINDING/);assert.equal(uploads,1);
 let deletes=0;const deletion=configured(async()=>{deletes++;return new Response('',{status:503});});
 await assert.rejects(deletion.call('b2_delete_file_version',{fileId:'generated'}),/B2_HTTP_503/);assert.equal(deletes,1);
});
test('download retries transport failure but checksum mismatch still fails closed',async()=>{
 const bytes=Buffer.from('generated'),object={fileName:'database/2026-10-19T00-00-00.000Z/manifest.json.enc',fileId:'generated',bytes:bytes.length,sha256:digest(bytes)};let calls=0;
 const store=configured(async()=>{if(calls++===0)throw Object.assign(TypeError('fetch failed'),{cause:{code:'ETIMEDOUT'}});return new Response(bytes);});
 assert.deepEqual(await store.get(object),bytes);assert.equal(calls,2);
 calls=0;const mismatch=configured(async()=>{calls++;return new Response(bytes)});
 await assert.rejects(mismatch.get({...object,sha256:'0'.repeat(64)}),/DOWNLOAD_HASH/);assert.equal(calls,1);
});

test('a provider wait beyond the retry budget fails rather than retrying too soon',async()=>{let calls=0;const failure=Object.assign(error(503),{retryAfter:'120'});await assert.rejects(retry(async()=>{calls++;throw failure;},{wait:async()=>assert.fail('Must not retry before provider permits'),...options}),e=>e===failure);assert.equal(calls,1);});

test('authorization retries still validate restricted private encrypted bucket before use',async()=>{
 let attempts=0;const waits=[],bucketName='acloud-staging-db-backups';
 const s=new BackupStore({bucketName,bucketId:'generated-bucket',keyId:'generated',applicationKey:'test_secret'},{wait:async n=>waits.push(n),...options,fetch:async url=>{
  if(url.includes('b2_authorize_account')){if(attempts++===0)return new Response('',{status:503});return Response.json({accountId:'generated',authorizationToken:'test_secret',apiInfo:{storageApi:{apiUrl:'https://api.backblazeb2.com',downloadUrl:'https://download.backblazeb2.com',allowed:{buckets:[{id:'generated-bucket',name:bucketName}],namePrefix:'database/',capabilities:['listBuckets','readBuckets','listFiles','readFiles','writeFiles']}}}});}
  assert.ok(url.endsWith('/b2_list_buckets'));return Response.json({buckets:[{bucketName,bucketType:'allPrivate',defaultServerSideEncryption:{value:{mode:'SSE-B2'}}}]});
 }});
 await s.connect();assert.equal(attempts,2);assert.deepEqual(waits,[1000]);
});
