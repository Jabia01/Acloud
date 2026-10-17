import 'reflect-metadata';
import {test} from 'node:test';import assert from 'node:assert/strict';import {randomUUID} from 'node:crypto';
import {requirePreviewResource,previewMaximumBytes} from '../src/restore/preview-policy';
import {RestoreService,protectedVersion} from '../src/restore/service';
const checksum='a'.repeat(64),display={media_type:'image',verified_size_bytes:100,expected_checksum:checksum};
const complete={kind:'LIVE_PHOTO',protection_state:'FULLY_PROTECTED',source_changed:false,integrity_degraded:false,review_required:false,role:'PRIMARY_STILL',expected_size:100,expected_sha256:checksum};
test('previews allow verified Live Photo still and edited render without restoring complex media',()=>{
 requirePreviewResource(display,[complete]);requirePreviewResource(display,[{...complete,kind:'EDITED',role:'EDITED_RENDER'}]);requirePreviewResource(display,[]);
});
test('previews reject partial, changed, degraded or review-required preservation',()=>{
 for(const change of [{protection_state:'PARTIAL'},{source_changed:true},{integrity_degraded:true},{review_required:true},{expected_size:99},{expected_sha256:'b'.repeat(64)},{kind:'COMPLEX'}])assert.throws(()=>requirePreviewResource(display,[{...complete,...change}]));
});
test('previews cannot authorize recipes, paired motion, unknown resources or oversized originals',()=>{
 for(const role of ['ADJUSTMENT_DATA','ADJUSTMENT_BASE','PAIRED_VIDEO','UNKNOWN_REQUIRED','DERIVED_PREVIEW'])assert.throws(()=>requirePreviewResource(display,[{...complete,role}]));
 for(const size of [0,-1,previewMaximumBytes+1,NaN])assert.throws(()=>requirePreviewResource({...display,verified_size_bytes:size},[]));
 assert.throws(()=>requirePreviewResource({...display,media_type:'test'},[]));
});
test('preview route retains device/session/asset/version/storage gates and ordinary restore remains blocked',async()=>{
 const saved={...process.env},id=randomUUID(),user=randomUUID(),session=randomUUID(),device=randomUUID();
 let active=true,blocked=false,resources=[{...complete}],signs=0,metadataAvailable=true;
 const asset={id,user_id:user,...display,status:'PROTECTED',storage_provider:'minio',storage_binding:'generated-binding',storage_object_key:'generated/key',storage_version_id:'generated-version'};
 const c={query:async(sql:string,args:unknown[]=[])=>{
  if(sql.includes('FROM sessions'))return{rows:active?[{id:session}]:[],rowCount:active?1:0};
  if(sql.includes('FROM assets a'))return{rows:args[0]===id&&args[1]===user?[asset]:[]};
  if(sql.includes('FROM asset_verifications'))return{rows:[{id:randomUUID()}]};
  if(sql.includes('media_manifest_summary'))return{rows:resources};
  if(sql.includes('beta_switches'))return{rows:[{blocked}]};
  return{rows:[],rowCount:1};
 }};
 const storage={identity:()=>({provider:'minio'}),assertBinding:()=>{},getObjectMetadata:async()=>metadataAvailable?{sizeBytes:100,versionId:'generated-version'}:null,createDownloadAuthorization:async()=>{signs++;return{method:'GET',url:'https://storage.example.invalid/generated',expiresAt:'2099-01-01T00:00:00.000Z'}}};
 const api=new RestoreService({transaction:async(fn:any)=>fn(c)} as any,storage as any,{} as any),p={userId:user,sessionId:session,deviceId:device};
 try{
  process.env.NODE_ENV='development';process.env.BETA_ENABLED='false';process.env.OWNER_DEVICE_TEST_ENABLED='false';process.env.DEVELOPMENT_RESTORE_TEST_ASSET_ID=id;
  const proof=await api.previewEvidence(p,id);assert.equal(proof.resourcePolicy,'VERIFIED_PREVIEW_RESOURCE');
  const body={cloudVersionId:protectedVersion(asset)};
  assert.equal((await api.previewAuthorize(p,id,body)).evidence.cloudVersionId,body.cloudVersionId);assert.equal(signs,1);
  assert.deepEqual(await api.previewRecheck(p,id,body),proof);
  await assert.rejects(api.evidence(p,id)); // still requires complete-media restore, no weakened restore path
  await assert.rejects(api.previewEvidence({...p,deviceId:undefined},id));
  await assert.rejects(api.previewEvidence({...p,userId:randomUUID()},id));
  active=false;await assert.rejects(api.previewEvidence(p,id));active=true;
  for(const body of [{cloudVersionId:'b'.repeat(64)},{cloudVersionId:proof.cloudVersionId,objectKey:'injected'}])await assert.rejects(api.previewAuthorize(p,id,body));
  metadataAvailable=false;await assert.rejects(api.previewAuthorize(p,id,body));metadataAvailable=true;
  resources=[{...complete,source_changed:true}];await assert.rejects(api.previewRecheck(p,id,body));resources=[{...complete}];
  process.env.DEVELOPMENT_RESTORE_TEST_ASSET_ID=randomUUID();process.env.RESTORE_ENABLED='false';await assert.rejects(api.previewAuthorize(p,id,body));
  assert.equal(signs,1,'rejected requests never sign downloads');
 }finally{for(const key of Object.keys(process.env))if(!(key in saved))delete process.env[key];Object.assign(process.env,saved);}
});
