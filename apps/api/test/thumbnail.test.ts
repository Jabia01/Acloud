import {savedThumbnailKey} from '../src/restore/saved-version';
import 'reflect-metadata';
import {test} from 'node:test';import assert from 'node:assert/strict';import {randomUUID,createHash} from 'node:crypto';
import {thumbnailInput,jpegDimensions,thumbnailAccountBudget} from '../src/restore/thumbnail-policy';
import {RestoreService,protectedVersion} from '../src/restore/service';
function jpeg(width=240,height=160){return Buffer.from([0xff,0xd8,0xff,0xc0,0,11,8,height>>8,height&255,width>>8,width&255,1,1,0x11,0,0xff,0xda,0,8,1,1,0,0,63,0,0x11,0xff,0xd9]);}
const version='a'.repeat(64),source='b'.repeat(64);
test('thumbnail inputs are strictly bounded JPEG derivatives with no EXIF',()=>{
 const bytes=jpeg(),input={cloudVersionId:version,sourceSha256:source,dataBase64:bytes.toString('base64')};
 assert.equal(thumbnailInput(input).width,240);assert.equal(thumbnailInput(input).height,160);
 for(const value of [null,[],{...input,url:'injected'},{...input,sourceSha256:'invalid'},{...input,dataBase64:'!!'}, {...input,dataBase64:Buffer.alloc(40961).toString('base64')}])assert.throws(()=>thumbnailInput(value));
 for(const bytes of [jpeg(241),jpeg(240,241),jpeg(0),Buffer.from('<svg></svg>'),Buffer.concat([Buffer.from([255,216,255,225,0,4,1,2]),jpeg().subarray(2)]),jpeg().subarray(0,10)])assert.throws(()=>jpegDimensions(bytes));
});
test('private thumbnails retain owner/device/version/preservation checks, immutable bytes and budgets',async()=>{
 const saved={...process.env},id=randomUUID(),user=randomUUID(),session=randomUUID(),device=randomUUID();
 const asset={id,user_id:user,media_type:'image',verified_size_bytes:100,expected_checksum:source,status:'PROTECTED',storage_provider:'minio',storage_binding:'generated-binding',storage_object_key:'generated/key',storage_version_id:'generated-version'};
 let active=true,rows:any[]=[],resources:any[]=[],usage={bytes:0,recent:0};
 const c={query:async(sql:string,args:any[]=[])=>{
  if(sql.includes('FROM sessions'))return{rows:active?[{id:session}]:[],rowCount:active?1:0};
  if(sql.startsWith('SELECT id FROM assets'))return{rows:args[0]===id&&args[1]===user&&args[2]===device?[{id}]:[]};
  if(sql.includes('FROM assets a'))return{rows:args[0]===id&&args[1]===user?[asset]:[]};
  if(sql.includes('FROM asset_verifications'))return{rows:[{id:randomUUID()}]};
  if(sql.includes('media_manifest_summary'))return{rows:resources};
  if(sql.includes('sum(octet_length'))return{rows:[usage]};
  if(sql.startsWith('SELECT * FROM saved_thumbnails'))return{rows:rows.filter(r=>r.asset_id===args[0]&&r.user_id===args[1]&&(args.length<4||r.cloud_version_id===args[2]&&r.source_sha256===args[3]))};
  if(sql.startsWith('INSERT INTO saved_thumbnails'))rows.push({asset_id:args[0],user_id:args[1],cloud_version_id:args[2],source_sha256:args[3],thumbnail_sha256:args[4],jpeg:args[5],width:args[6],height:args[7]});
  return{rows:[],rowCount:1};
 }};
 const storage={identity:()=>({provider:'minio'}),assertBinding:()=>{}},api=new RestoreService({transaction:async(fn:any)=>fn(c)} as any,storage as any,{} as any),p={userId:user,sessionId:session,deviceId:device},bytes=jpeg(),body={cloudVersionId:protectedVersion(asset),sourceSha256:source,dataBase64:bytes.toString('base64')};
 try{
  process.env.NODE_ENV='development';process.env.BETA_ENABLED='false';process.env.OWNER_DEVICE_TEST_ENABLED='false';process.env.DEVELOPMENT_RESTORE_TEST_ASSET_ID=id;
  await assert.rejects(api.thumbnail(p,id));
  assert.equal((await api.thumbnailEvidence(p,id)).expectedSha256,source);
  for(const principal of [{...p,deviceId:undefined},{...p,userId:randomUUID()}]){await assert.rejects(api.saveThumbnail(principal,id,body));await assert.rejects(api.thumbnail(principal,id));}
  active=false;await assert.rejects(api.saveThumbnail(p,id,body));active=true;
  await assert.rejects(api.saveThumbnail(p,id,{...body,sourceSha256:'c'.repeat(64)}));
  await assert.rejects(api.saveThumbnail(p,id,{...body,cloudVersionId:version}));
  usage={bytes:thumbnailAccountBudget,recent:0};await assert.rejects(api.saveThumbnail(p,id,body));usage={bytes:0,recent:600};await assert.rejects(api.saveThumbnail(p,id,body));usage={bytes:0,recent:0};
  assert.deepEqual(await api.saveThumbnail(p,id,body),{stored:true});
  const result=await api.thumbnail(p,id);assert.equal(result.dataBase64,body.dataBase64);assert.equal(result.thumbnailSha256,createHash('sha256').update(bytes).digest('hex'));
  await api.saveThumbnail(p,id,{...body,dataBase64:jpeg(100,100).toString('base64')});assert.equal(rows.length,1);assert.equal((await api.thumbnail(p,id)).dataBase64,body.dataBase64);
  resources=[{kind:'LIVE_PHOTO',protection_state:'PARTIAL',role:'PRIMARY_STILL',expected_size:100,expected_sha256:source}];await assert.rejects(api.thumbnail(p,id));resources=[];
  process.env.DEVELOPMENT_RESTORE_TEST_ASSET_ID=randomUUID();process.env.RESTORE_ENABLED='false';assert.equal((await api.thumbnail(p,id)).assetId,id);process.env.THUMBNAILS_ENABLED='false';await assert.rejects(api.thumbnail(p,id));
 }finally{for(const key of Object.keys(process.env))if(!(key in saved))delete process.env[key];Object.assign(process.env,saved);}
});

test('gallery cache key is invalidated by any saved storage version change',()=>{
 const asset={storage_provider:'minio',storage_binding:'generated',storage_object_key:'generated-object',storage_version_id:'version-one'};
 const valid={...asset,thumbnail_cloud_version:protectedVersion(asset),thumbnail_sha256:'a'.repeat(64)};
 assert.ok(savedThumbnailKey(valid));assert.equal(savedThumbnailKey({...valid,storage_version_id:'version-two'}),null);assert.equal(savedThumbnailKey({...valid,thumbnail_sha256:'invalid'}),null);
});
