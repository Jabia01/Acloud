// Run after API build: node --env-file=.env --test apps/api/test/owner-device-test.test.mjs
// Refuses non-local databases; creates and removes only a randomly named test schema.
import {describe,test,before,after,beforeEach} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {createRequire} from 'node:module';
import pg from 'pg';
import {migrate} from '../../../scripts/migrate.mjs';
const require=createRequire(import.meta.url);
const {DatabaseService}=require('../dist/database.service.js');
const {BetaPolicy}=require('../dist/beta/policy.js');
const {BetaRequestGuard}=require('../dist/beta/module.js');
const {UploadService}=require('../dist/uploads/upload.service.js');
const {RestoreService}=require('../dist/restore/service.js');
const {ObjectStorageProvider}=require('../dist/uploads/storage.js');
const {ownerTestBinding,ownerTestConfiguration,ownerTestIdentity}=require('../dist/beta/owner-test.js');
const off=['BETA_ENABLED','BETA_ALLOW_REAL_MEDIA','BETA_ALLOW_B2','BETA_ALLOW_PAYMENTS','BETA_ALLOW_FREE_UP_SPACE','BETA_ALLOW_SUPPORT_TOOLS','CUSTOMER_REGISTRATION_ENABLED','BILLING_ENABLED','ENABLE_FREE_UP_SPACE','ACCOUNT_DELETION_ENABLED','ACCOUNT_DELETION_EXECUTION_ENABLED','RETENTION_EXECUTION_ENABLED','RESTORE_ENABLED'];
class FixtureStorage extends ObjectStorageProvider {
 identity(){return{provider:'backblaze_b2',binding:'a'.repeat(64),environment:'staging'};}
 async isHealthy(){return true;}
 async beginMultipart(){return 'fixture-multipart';}
 async authorizePart(){return{method:'PUT',url:'https://fixture.invalid/part',headers:{},expiresAt:new Date(Date.now()+60000).toISOString()};}
 async getObjectMetadata(){return {sizeBytes:100,versionId:'fixture-version'};}
 async verifyObject(_key,size,checksum){return{ok:true,sizeBytes:size,checksum,versionId:'fixture-version'};}
 async createDownloadAuthorization(_key,version){return{method:'GET',url:'https://fixture.invalid/download',version,expiresAt:new Date(Date.now()+60000).toISOString()};}
}
describe('private owner device staging mode',{concurrency:false},()=>{
 const saved={...process.env},schema='owner_test_'+randomUUID().replaceAll('-','');
 let root,pool,db,policy,uploads,restore,p;
 const storage=new FixtureStorage();
 const input=(size=100)=>({mediaType:'image',size,checksum:'a'.repeat(64),deviceId:p.deviceId,multipart:true,requestHash:'b'.repeat(64)});
 async function protectedAsset(){const r=await uploads.create(p,input(),randomUUID());await uploads.multipartStart(p,r.id);await uploads.completeMultipart(p,r.id);assert.equal((await uploads.complete(p,r.id)).status,'PROTECTED');return r;}
 before(async()=>{
   const original=new URL(process.env.DATABASE_URL);assert.ok(['localhost','127.0.0.1'].includes(original.hostname),'Local isolated tests only');
   delete process.env.DATABASE_CA_FILE;
   root=new pg.Pool({connectionString:original.href});await root.query('CREATE SCHEMA '+schema);
   original.searchParams.set('options','-c search_path='+schema);process.env.DATABASE_URL=original.href;
   assert.equal(await migrate(),18);pool=new pg.Pool({connectionString:original.href});db=new DatabaseService();policy=new BetaPolicy(db);uploads=new UploadService(db,storage,policy);restore=new RestoreService(db,storage,policy);
 });
 beforeEach(async()=>{
   p={userId:randomUUID(),deviceId:randomUUID(),sessionId:randomUUID()};
   await pool.query('INSERT INTO users(id,email,email_normalized,password_hash,email_verified_at) VALUES($1,$2,$2,$3,now())',[p.userId,p.userId+'@example.invalid','fixture']);
   await pool.query("INSERT INTO devices(id,user_id,device_identifier,display_name,platform) VALUES($1,$2,$3,'Fixture','ios')",[p.deviceId,p.userId,p.deviceId]);
   await pool.query("INSERT INTO sessions(id,user_id,device_id,token_hash,expires_at) VALUES($1,$2,$3,$4,now()+interval '1 hour')",[p.sessionId,p.userId,p.deviceId,randomUUID().replaceAll('-','').repeat(2)]);
   await pool.query('INSERT INTO development_entitlements(user_id,quota_bytes) VALUES($1,67108864)',[p.userId]);
   await pool.query("UPDATE beta_switches SET blocked=false WHERE name IN ('uploads','multipart','downloads','restore')");
   delete process.env.OWNER_DEVICE_TEST_PROFILE;
   for(const key of off)process.env[key]='false';
   Object.assign(process.env,{NODE_ENV:'production',APP_ENV:'staging',STORAGE_ENVIRONMENT:'staging',STORAGE_PROVIDER:'backblaze_b2',B2_BUCKET_NAME:'owner-test-fixture',BETA_EXPECTED_BUCKET:'owner-test-fixture',API_PUBLIC_ORIGIN:'https://api.example.invalid',B2_S3_ENDPOINT:'https://s3.eu-central-003.backblazeb2.com',OWNER_DEVICE_TEST_ENABLED:'true',OWNER_DEVICE_TEST_ACCOUNT_ID:p.userId,OWNER_DEVICE_TEST_DEVICE_ID:p.deviceId,OWNER_DEVICE_TEST_STARTS_AT:new Date(Date.now()-1000).toISOString(),OWNER_DEVICE_TEST_EXPIRES_AT:new Date(Date.now()+3600000).toISOString()});
   process.env.OWNER_DEVICE_TEST_RESOURCE_HASH=ownerTestBinding(process.env);
 });
 after(async()=>{await db?.onApplicationShutdown();await pool?.end();if(root){await root.query('DROP SCHEMA IF EXISTS '+schema+' CASCADE');await root.end();}for(const key of Object.keys(process.env))if(!(key in saved))delete process.env[key];Object.assign(process.env,saved);});
 test('closed startup accepts test configuration without recording beta acceptance',async()=>{await policy.startup();assert.equal((await pool.query('SELECT count(*)::int n FROM beta_acceptance')).rows[0].n,0);assert.equal((await policy.admission('REAL_MEDIA')).accepted,false);});
 test('disabled mode still rejects staging uploads',async()=>{process.env.OWNER_DEVICE_TEST_ENABLED='false';await assert.rejects(uploads.create(p,input(),randomUUID()));});
 for(const key of off)test('refuses broader feature '+key,()=>{process.env[key]='true';assert.throws(()=>ownerTestConfiguration());});
 for(const patch of [{APP_ENV:'production'},{NODE_ENV:'development'},{STORAGE_PROVIDER:'minio'},{STORAGE_ENVIRONMENT:'production'},{B2_BUCKET_NAME:'acloud-prod-media'},{B2_S3_ENDPOINT:'http://localhost:9000'},{OWNER_DEVICE_TEST_RESOURCE_HASH:'0'.repeat(64)},{OWNER_DEVICE_TEST_ENABLED:'yes'}])test('rejects unsafe binding '+Object.keys(patch)[0],()=>{Object.assign(process.env,patch);assert.throws(()=>ownerTestConfiguration());});
 test('future, expired and overlong windows rejected',()=>{const cfg=ownerTestConfiguration();assert.throws(()=>ownerTestIdentity(p,process.env,cfg.start-1));assert.throws(()=>ownerTestIdentity(p,process.env,cfg.end));process.env.OWNER_DEVICE_TEST_EXPIRES_AT=new Date(cfg.start+86400001).toISOString();assert.throws(()=>ownerTestConfiguration());});
 test('project profile permits 31 days and rejects longer or unknown profiles',()=>{
  process.env.OWNER_DEVICE_TEST_PROFILE='project';const start=Date.now()-1000;
  process.env.OWNER_DEVICE_TEST_STARTS_AT=new Date(start).toISOString();
  process.env.OWNER_DEVICE_TEST_EXPIRES_AT=new Date(start+31*86400000).toISOString();
  const cfg=ownerTestIdentity(p);assert.equal(cfg.maxFiles,100);assert.equal(cfg.maxBytes,1073741824);
  assert.throws(()=>ownerTestIdentity({...p,deviceId:randomUUID()}));
  assert.throws(()=>ownerTestIdentity(p,process.env,cfg.end));
  process.env.OWNER_DEVICE_TEST_EXPIRES_AT=new Date(start+31*86400000+1).toISOString();assert.throws(()=>ownerTestConfiguration());
  process.env.OWNER_DEVICE_TEST_PROFILE='unlimited';assert.throws(()=>ownerTestConfiguration());
 });
 test('project profile admits three verified backups and includes all in restore',async()=>{
  process.env.OWNER_DEVICE_TEST_PROFILE='project';
  for(let i=0;i<3;i++)await protectedAsset();
  assert.equal((await restore.status(p)).OWNER_DEVICE_TEST_ASSET_IDS.length,3);
  process.env.OWNER_DEVICE_TEST_ENABLED='false';await assert.rejects(uploads.create(p,input(),randomUUID()));
 });
 test('project profile still enforces ordinary quota',async()=>{
  process.env.OWNER_DEVICE_TEST_PROFILE='project';
  await pool.query('UPDATE entitlements SET quota_bytes=10 WHERE user_id=$1',[p.userId]);await assert.rejects(uploads.create(p,input(),randomUUID()));
 });
 test('project allowance enforces 100 attempts and 1 GiB including cancelled attempts',async()=>{
  process.env.OWNER_DEVICE_TEST_PROFILE='project';
  const {ownerTestUpload}=require('../dist/beta/owner-test.js');let count=99,bytes=1073741724;
  const client={query:async(sql)=>{
   if(sql.includes('FROM sessions'))return {rowCount:1,rows:[{}]};
   if(sql.includes('FROM beta_switches'))return {rows:[{name:'uploads',blocked:false},{name:'multipart',blocked:false}]};
   if(sql.includes('idempotency_key'))return {rows:[]};
   if(sql.includes('count(*)')){assert.ok(!sql.includes("status="));return {rows:[{count,bytes:String(bytes)}]};}
   throw Error('Unexpected query');
  }};
  await ownerTestUpload(client,p,{...input(),key:randomUUID()});
  count=100;await assert.rejects(ownerTestUpload(client,p,{...input(),key:randomUUID()}));
  count=99;bytes++;await assert.rejects(ownerTestUpload(client,p,{...input(),key:randomUUID()}));
 });
 test('wrong account, wrong device and browser sessions denied',async()=>{for(const patch of [{userId:randomUUID()},{deviceId:randomUUID()},{deviceId:null}])await assert.rejects(uploads.create({...p,...patch},input(),randomUUID()));});
 test('revoked session and device denied before signing',async()=>{await pool.query('UPDATE sessions SET revoked_at=now() WHERE id=$1',[p.sessionId]);await assert.rejects(uploads.create(p,input(),randomUUID()));await pool.query('UPDATE sessions SET revoked_at=NULL WHERE id=$1',[p.sessionId]);await pool.query('UPDATE devices SET revoked_at=now() WHERE id=$1',[p.deviceId]);await assert.rejects(uploads.create(p,input(),randomUUID()));});
 test('unverified and abuse-reviewed accounts denied',async()=>{await pool.query('UPDATE users SET email_verified_at=NULL WHERE id=$1',[p.userId]);await assert.rejects(uploads.create(p,input(),randomUUID()));await pool.query('UPDATE users SET email_verified_at=now(),abuse_review=true WHERE id=$1',[p.userId]);await assert.rejects(uploads.create(p,input(),randomUUID()));});
 test('file size, single upload and spoofed device denied',async()=>{for(const patch of [{size:33554433},{multipart:false},{deviceId:randomUUID()}])await assert.rejects(uploads.create(p,{...input(),...patch},randomUUID()));});
 test('concurrent reservations cap at two and preserve quota',async()=>{const results=await Promise.allSettled(Array.from({length:5},()=>uploads.create(p,input(33554432),randomUUID())));assert.equal(results.filter(r=>r.status==='fulfilled').length,2);assert.equal(Number((await pool.query('SELECT reserved_bytes FROM development_entitlements WHERE user_id=$1',[p.userId])).rows[0].reserved_bytes),67108864);});
 test('global request guard admits only the bound live owner session',async()=>{
  const token='x'.repeat(43);const {createHash}=await import('node:crypto');
  await pool.query('UPDATE sessions SET token_hash=$2 WHERE id=$1',[p.sessionId,createHash('sha256').update(token).digest('hex')]);
  const guard=new BetaRequestGuard(policy,db);
  const ctx=(path='/uploads',authorization='Bearer '+token)=>({switchToHttp:()=>({getRequest:()=>({method:'POST',path,headers:{authorization}})})});
  assert.equal(await guard.canActivate(ctx()),true);
  const {Controller,Post,Module}=require('@nestjs/common');const {NestFactory,APP_GUARD}=require('@nestjs/core');
  class ProbeController{create(){return {admitted:true};}}
  Controller('uploads')(ProbeController);Post()(ProbeController.prototype,'create',Object.getOwnPropertyDescriptor(ProbeController.prototype,'create'));
  class ProbeModule{};Module({controllers:[ProbeController],providers:[{provide:APP_GUARD,useValue:guard}]})(ProbeModule);
  const app=await NestFactory.create(ProbeModule,{logger:false});
  try{await app.listen(0,'127.0.0.1');const url=await app.getUrl();
   assert.equal((await fetch(url+'/uploads',{method:'POST',headers:{authorization:'Bearer '+token}})).status,201);
   assert.equal((await fetch(url+'/uploads',{method:'POST'})).status,403);
   const old=process.env.OWNER_DEVICE_TEST_ACCOUNT_ID;process.env.OWNER_DEVICE_TEST_ACCOUNT_ID=randomUUID();
   try{assert.equal((await fetch(url+'/uploads',{method:'POST',headers:{authorization:'Bearer '+token}})).status,403);}finally{process.env.OWNER_DEVICE_TEST_ACCOUNT_ID=old;}
  }finally{await app.close();}

  assert.equal(await guard.canActivate(ctx('/uploads/'+randomUUID()+'/multipart')),true);
  await assert.rejects(guard.canActivate(ctx('/billing/checkout')));
  await assert.rejects(guard.canActivate(ctx('/storage/free-up-space')));
  await assert.rejects(guard.canActivate(ctx('/uploads','')));
  await assert.rejects(guard.canActivate(ctx('/uploads','Bearer '+'y'.repeat(43))));
  process.env.OWNER_DEVICE_TEST_DEVICE_ID=randomUUID();await assert.rejects(guard.canActivate(ctx()));process.env.OWNER_DEVICE_TEST_DEVICE_ID=p.deviceId;
  await pool.query("UPDATE beta_switches SET blocked=true WHERE name='multipart'");await assert.rejects(guard.canActivate(ctx()));await pool.query("UPDATE beta_switches SET blocked=false WHERE name='multipart'");
  await pool.query('UPDATE sessions SET revoked_at=now() WHERE id=$1',[p.sessionId]);await assert.rejects(guard.canActivate(ctx()));
 });
 test('global request guard keeps uploads closed with owner mode off',async()=>{
  process.env.OWNER_DEVICE_TEST_ENABLED='false';
  const guard=new BetaRequestGuard(policy,db);
  await assert.rejects(guard.canActivate({switchToHttp:()=>({getRequest:()=>({method:'POST',path:'/uploads',headers:{}})})}));
 });
 test('native multipart request binds omitted device to authenticated iPad',async()=>{const r=await uploads.create(p,{...input(),deviceId:null},randomUUID());assert.equal((await pool.query('SELECT device_id FROM assets WHERE id=$1',[r.assetId])).rows[0].device_id,p.deviceId);});
 test('ordinary quota remains enforced',async()=>{await pool.query('UPDATE entitlements SET quota_bytes=10 WHERE user_id=$1',[p.userId]);await assert.rejects(uploads.create(p,input(),randomUUID()));});
 test('idempotency retry does not spend a second slot; cancelled attempts still count',async()=>{const key=randomUUID(),a=await uploads.create(p,input(),key);assert.equal((await uploads.create(p,input(),key)).id,a.id);await uploads.create(p,input(),randomUUID());await uploads.cancel(p,a.id);await assert.rejects(uploads.create(p,input(),randomUUID()));});
 test('old assets and old idempotency keys cannot enter test scope',async()=>{const key=randomUUID(),r=await uploads.create(p,input(),key);await pool.query("UPDATE assets SET created_at=now()-interval '2 days' WHERE id=$1",[r.assetId]);await assert.rejects(uploads.create(p,input(),key));await assert.rejects(uploads.multipartStart(p,r.id));});
 test('pause, expiry and revocation stop new part URLs and completion',async()=>{const r=await uploads.create(p,input(),randomUUID());await uploads.multipartStart(p,r.id);await pool.query("UPDATE beta_switches SET blocked=true WHERE name='multipart'");await assert.rejects(uploads.authorizePart(p,r.id,1,{size_bytes:100,checksum_sha256:'a'.repeat(64)}));await assert.rejects(uploads.completeMultipart(p,r.id));await pool.query("UPDATE beta_switches SET blocked=false WHERE name='multipart'");process.env.OWNER_DEVICE_TEST_EXPIRES_AT=new Date(Date.now()-1).toISOString();await assert.rejects(uploads.parts(p,r.id));});
 test('verification, pinned restore and status are scoped without beta approval',async()=>{const r=await protectedAsset();const status=await restore.status(p);assert.equal(status.RESTORE_BETA_ACCEPTED,false);assert.equal(status.OWNER_DEVICE_TEST,true);assert.deepEqual(status.OWNER_DEVICE_TEST_ASSET_IDS,[r.assetId]);const proof=await restore.evidence(p,r.assetId);const result=await restore.authorize(p,r.assetId,{cloudVersionId:proof.cloudVersionId});assert.equal(result.authorization.version,'fixture-version');await assert.rejects(restore.authorize(p,r.assetId,{cloudVersionId:'0'.repeat(64)}));await assert.rejects(restore.evidence({...p,deviceId:randomUUID()},r.assetId));});
 test('unprotected asset cannot restore',async()=>{const r=await uploads.create(p,input(),randomUUID());await assert.rejects(restore.evidence(p,r.assetId));assert.deepEqual((await restore.status(p)).OWNER_DEVICE_TEST_ASSET_IDS,[]);});
 test('download/restore pause and expiration cover both routes',async()=>{const r=await protectedAsset();await pool.query("UPDATE beta_switches SET blocked=true WHERE name='downloads'");await assert.rejects(uploads.download(p,r.assetId));await assert.rejects(restore.evidence(p,r.assetId));await pool.query("UPDATE beta_switches SET blocked=false WHERE name='downloads'");process.env.OWNER_DEVICE_TEST_EXPIRES_AT=new Date(Date.now()-1).toISOString();await assert.rejects(uploads.download(p,r.assetId));assert.deepEqual(await restore.status(p),{RESTORE_BETA_ACCEPTED:false});});
 test('disabling mode revokes new downloads for the configured owner',async()=>{const r=await protectedAsset();process.env.OWNER_DEVICE_TEST_ENABLED='false';await assert.rejects(uploads.download(p,r.assetId));await assert.rejects(restore.evidence(p,r.assetId));});
 test('signed URL lifetime cannot exceed the test window',async()=>{const {ownerTestTTL}=require('../dist/beta/owner-test.js');process.env.OWNER_DEVICE_TEST_EXPIRES_AT=new Date(Date.now()+10000).toISOString();assert.ok(ownerTestTTL(300)<=10);});
 test('checksum failure never becomes protected',async()=>{const r=await uploads.create(p,input(),randomUUID());await uploads.multipartStart(p,r.id);await uploads.completeMultipart(p,r.id);const verify=storage.verifyObject;storage.verifyObject=async()=>({ok:false,code:'CHECKSUM_MISMATCH'});try{assert.equal((await uploads.complete(p,r.id)).status,'FAILED');await assert.rejects(restore.evidence(p,r.assetId));}finally{storage.verifyObject=verify;}});
});
