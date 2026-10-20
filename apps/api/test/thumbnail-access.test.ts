import 'reflect-metadata';
import test from 'node:test';import assert from 'node:assert/strict';import {randomUUID} from 'node:crypto';
import {thumbnailAccess} from '../src/restore/thumbnail-access';
import {ownerTestBinding,ownerTestIdentity} from '../src/beta/owner-test';
test('restricted thumbnails allow the same owner browser to read, never publish or obtain restore identity',async()=>{
 const original={...process.env},account=randomUUID(),device=randomUUID(),browser=randomUUID(),asset=randomUUID();
 try{
  Object.assign(process.env,{NODE_ENV:'production',APP_ENV:'staging',STORAGE_ENVIRONMENT:'staging',STORAGE_PROVIDER:'backblaze_b2',OWNER_DEVICE_TEST_ENABLED:'true',OWNER_DEVICE_TEST_ACCOUNT_ID:account,OWNER_DEVICE_TEST_DEVICE_ID:device,OWNER_DEVICE_TEST_STARTS_AT:new Date(Date.now()-60000).toISOString(),OWNER_DEVICE_TEST_EXPIRES_AT:new Date(Date.now()+3600000).toISOString(),DATABASE_URL:'postgresql://fixture@localhost/fixture',B2_BUCKET_NAME:'generated-staging',BETA_EXPECTED_BUCKET:'generated-staging',API_PUBLIC_ORIGIN:'https://api.example.invalid',B2_S3_ENDPOINT:'https://s3.example.invalid'});
  for(const key of ['BETA_ENABLED','BETA_ALLOW_REAL_MEDIA','BETA_ALLOW_B2','BETA_ALLOW_PAYMENTS','BETA_ALLOW_FREE_UP_SPACE','BETA_ALLOW_SUPPORT_TOOLS','CUSTOMER_REGISTRATION_ENABLED','BILLING_ENABLED','ENABLE_FREE_UP_SPACE','ACCOUNT_DELETION_ENABLED','ACCOUNT_DELETION_EXECUTION_ENABLED','RETENTION_EXECUTION_ENABLED','RESTORE_ENABLED'])process.env[key]='false';
  process.env.OWNER_DEVICE_TEST_RESOURCE_HASH=ownerTestBinding(process.env);
  let live=true,allowedAsset=true,platform='web';
  const c={query:async(sql:string,args:any[])=>{
   if(sql.includes('FROM sessions'))return{rows:live&&args[1]===account&&(args[2]===device||!args[4]&&platform==='web')?[{id:args[0]}]:[]};
   if(sql.includes('FROM assets'))return{rows:allowedAsset&&args[0]===asset&&args[1]===account&&args[2]===device?[{id:asset}]:[]};
   throw Error('Unexpected query');
  }} as any;
  const p={userId:account,sessionId:randomUUID(),deviceId:browser};
  await thumbnailAccess(c,p,asset,false,{} as any);
  await assert.rejects(thumbnailAccess(c,p,asset,true,{} as any));
  assert.throws(()=>ownerTestIdentity(p),'Browser still cannot pass full restore identity');
  await thumbnailAccess(c,{...p,deviceId:device},asset,true,{} as any);
  for(const other of [{...p,userId:randomUUID()},{...p,deviceId:null}])await assert.rejects(thumbnailAccess(c,other,asset,false,{} as any));
  live=false;await assert.rejects(thumbnailAccess(c,p,asset,false,{} as any));live=true;
  allowedAsset=false;await assert.rejects(thumbnailAccess(c,p,asset,false,{} as any));allowedAsset=true;
  platform='ios';await assert.rejects(thumbnailAccess(c,p,asset,false,{} as any));platform='web';
  process.env.THUMBNAILS_ENABLED='false';await assert.rejects(thumbnailAccess(c,p,asset,false,{} as any));delete process.env.THUMBNAILS_ENABLED;
  process.env.OWNER_DEVICE_TEST_EXPIRES_AT=new Date(Date.now()-1).toISOString();await assert.rejects(thumbnailAccess(c,p,asset,false,{} as any));
 }finally{for(const key of Object.keys(process.env))if(!(key in original))delete process.env[key];Object.assign(process.env,original)}
});
