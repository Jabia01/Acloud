import {createHash} from 'node:crypto';
export type StorageConfig={
 provider:'minio'|'backblaze_b2';environment:'development'|'test'|'staging'|'production';
 endpoint:string;publicEndpoint:string;region:string;bucket:string;keyId:string;secret:string;
};
const localHosts=['localhost','127.0.0.1','storage'];
function origin(value:string){
 const u=new URL(value);
 if(u.username||u.password||u.search||u.hash||u.pathname!=='/'||!['http:','https:'].includes(u.protocol))throw new Error();
 return u;
}
export function storageConfig(env:NodeJS.ProcessEnv=process.env):StorageConfig{
 const node=env.NODE_ENV??'development';
 const provider=env.STORAGE_PROVIDER??(node==='production'?'':'minio');
 const environment=env.STORAGE_ENVIRONMENT??node;
 if(!['development','test','staging','production'].includes(environment)||!['minio','backblaze_b2'].includes(provider)||
    node==='production'&&(provider!=='backblaze_b2'||environment!==(env.APP_ENV==='staging'?'staging':'production'))||node!=='production'&&['production','staging'].includes(environment)){
  throw new Error('Invalid storage configuration');
 }
 const b2=provider==='backblaze_b2';
 const bucket=(b2?env.B2_BUCKET_NAME:env.S3_BUCKET)??'';
 const region=(b2?env.B2_REGION:env.S3_REGION)??(b2?'':'us-east-1');
 const keyId=(b2?env.B2_KEY_ID:env.S3_ACCESS_KEY_ID)??'';
 const secret=(b2?env.B2_APPLICATION_KEY:env.S3_SECRET_ACCESS_KEY)??'';
 let endpoint:string,publicEndpoint:string;
 try{
  const u=origin((b2?env.B2_S3_ENDPOINT:env.S3_ENDPOINT)??'');
  if(b2){
   if(u.protocol!=='https:'||u.port||u.hostname!==`s3.${region}.backblazeb2.com`||!/^[-a-z0-9]+$/.test(region))throw new Error();
  }else if(!localHosts.includes(u.hostname))throw new Error();
  endpoint=u.origin;
  const p=origin(b2?endpoint:env.S3_PUBLIC_ENDPOINT??endpoint);
  if(!b2&&!(localHosts.includes(p.hostname) || (node!=='production' && p.hostname.endsWith('.local'))))throw new Error();
  publicEndpoint=p.origin;
 }catch{throw new Error('Invalid storage configuration');}
 if(!bucket||!keyId||!secret||!/^[-a-zA-Z0-9.]{3,63}$/.test(bucket))throw new Error('Storage configuration unavailable');
 if(b2&&!['production','staging'].includes(environment)&&(environment!=='test'||env.ALLOW_LIVE_STORAGE_TESTS!=='true'||env.EXPECTED_TEST_BUCKET!==bucket)){
  throw new Error('Live storage test safeguards required');
 }
 return{provider:provider as StorageConfig['provider'],environment:environment as StorageConfig['environment'],endpoint,publicEndpoint,region,bucket,keyId,secret};
}
// Credentials are deliberately excluded, allowing rotation without moving existing assets.
export function storageBinding(config:StorageConfig){
 return createHash('sha256').update(JSON.stringify([config.provider,config.environment,config.endpoint,config.bucket])).digest('hex');
}
export function liveTestConfig(env:NodeJS.ProcessEnv=process.env){
 if(env.NODE_ENV==='production'||env.STORAGE_PROVIDER!=='backblaze_b2'||env.STORAGE_ENVIRONMENT!=='test'||
    env.ALLOW_LIVE_STORAGE_TESTS!=='true'||!env.EXPECTED_TEST_BUCKET||env.EXPECTED_TEST_BUCKET!==env.B2_BUCKET_NAME){
  throw new Error('Explicit isolated live test bucket required');
 }
 return storageConfig(env);
}
export function ownedTestKey(key:string,runId:string){
 const uuid='[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}';
 return new RegExp(`^${uuid}$`,'i').test(runId)&&new RegExp(`^test/${runId}/${uuid}$`).test(key);
}
