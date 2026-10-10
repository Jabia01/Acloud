import 'reflect-metadata';
import {test} from 'node:test';import assert from 'node:assert/strict';import {randomUUID} from 'node:crypto';
import {developmentRestoreAsset,RestoreService} from '../src/restore/service';
const id=randomUUID();
test('single-media restore opt-in is local development only',()=>{
 assert.equal(developmentRestoreAsset({NODE_ENV:'development',DEVELOPMENT_RESTORE_TEST_ASSET_ID:id}),id);
 for(const NODE_ENV of ['test','production',undefined])assert.equal(developmentRestoreAsset({NODE_ENV,DEVELOPMENT_RESTORE_TEST_ASSET_ID:id}),undefined);
 for(const change of [{STORAGE_PROVIDER:'backblaze_b2'},{BETA_ENABLED:'true'},{DEVELOPMENT_RESTORE_TEST_ASSET_ID:'*'}])assert.equal(developmentRestoreAsset({NODE_ENV:'development',DEVELOPMENT_RESTORE_TEST_ASSET_ID:id,...change}),undefined);
});
test('development restore rejects another asset, unbound device and another owner',async()=>{
 const saved={...process.env};
 try{
  process.env.NODE_ENV='development';process.env.BETA_ENABLED='false';process.env.DEVELOPMENT_RESTORE_TEST_ASSET_ID=id;
  const c={query:async(sql:string)=>({rows:sql.includes('beta_switches')?[{blocked:true}]:[],rowCount:0})};
  const service=new RestoreService({} as any,{identity:()=>({provider:'minio'})} as any,{} as any);
  const p={userId:randomUUID(),sessionId:randomUUID(),deviceId:randomUUID()};
  await assert.rejects(()=>(service as any).gate(c,p,randomUUID()));
  await assert.rejects(()=>(service as any).gate(c,{...p,deviceId:null},id));
  await assert.rejects(()=>(service as any).gate(c,p,id));
 }finally{for(const key of Object.keys(process.env))if(!(key in saved))delete process.env[key];Object.assign(process.env,saved);}
});

test('same approved UUID accepts uppercase without accepting a different asset',async()=>{
 const saved={...process.env};
 try{
  process.env.NODE_ENV='development';process.env.BETA_ENABLED='false';process.env.DEVELOPMENT_RESTORE_TEST_ASSET_ID=id;
  const service=new RestoreService({} as any,{identity:()=>({provider:'minio'})} as any,{} as any);
  let checked:string|undefined;
  (service as any).asset=async(_c:unknown,_p:unknown,asset:string)=>{checked=asset;return{media_type:'image'}};
  await (service as any).gate({}, {deviceId:randomUUID()},id.toUpperCase());
  assert.equal(checked,id.toUpperCase());
 }finally{for(const key of Object.keys(process.env))if(!(key in saved))delete process.env[key];Object.assign(process.env,saved);}
});

test('development restore allows the approved video but rejects generated files',async()=>{
 const saved={...process.env};
 try{
  process.env.NODE_ENV='development';process.env.BETA_ENABLED='false';process.env.DEVELOPMENT_RESTORE_TEST_ASSET_ID=id;
  const service=new RestoreService({} as any,{identity:()=>({provider:'minio'})} as any,{} as any);
  (service as any).asset=async()=>({media_type:'video'});
  await (service as any).gate({}, {deviceId:randomUUID()},id);
  (service as any).asset=async()=>({media_type:'test'});
  await assert.rejects(()=>(service as any).gate({}, {deviceId:randomUUID()},id));
 }finally{for(const key of Object.keys(process.env))if(!(key in saved))delete process.env[key];Object.assign(process.env,saved);}
});
