import {retry as retryOperation} from './retry.mjs';
import {createHash} from 'node:crypto';import {BUCKET,trustedUrl,validateScope,validObject,expiredVersions,overdue,validSuccess} from './policy.mjs';
export const digest=(x,kind='sha256')=>createHash(kind).update(x).digest('hex');
export class BackupStore{
 constructor(credentials,{fetch:fetcher=globalThis.fetch,wait,random,now}={}){this.credentials=credentials;this.fetch=fetcher;this.retryOptions={wait,random,now};}
 async request(url,options={},{retry=false,consume=async r=>r}={}){
  const endpoint=trustedUrl(url);const operation=async()=>{
   const r=await this.fetch(endpoint,{...options,redirect:'error',signal:AbortSignal.timeout(60000)});
   if(!r.ok){await r.body?.cancel().catch(()=>{});const error=Error('B2_HTTP_'+r.status);error.status=r.status;error.retryAfter=r.headers.get('Retry-After');throw error;}
   return consume(r);
  };
  return retry?retryOperation(operation,this.retryOptions):operation();
 }
 async connect(){const c=this.credentials;this.auth=await this.request('https://api.backblazeb2.com/b2api/v4/b2_authorize_account',{headers:{Authorization:'Basic '+Buffer.from(c.keyId+':'+c.applicationKey).toString('base64')}},{retry:true,consume:r=>r.json()});this.api=this.auth.apiInfo.storageApi;validateScope(c,this.api.allowed);const bucket=(await this.call('b2_list_buckets',{accountId:this.auth.accountId,bucketId:c.bucketId})).buckets?.[0];if(bucket?.bucketName!==BUCKET||bucket.bucketType!=='allPrivate'||bucket.defaultServerSideEncryption?.value?.mode!=='SSE-B2')throw Error('PRIVATE_ENCRYPTED_BUCKET_REQUIRED');}
 async call(method,data,{retry=true}={}){const safe=['b2_list_buckets','b2_list_file_versions','b2_get_upload_url'].includes(method);return this.request(this.api.apiUrl+'/b2api/v4/'+method,{method:'POST',headers:{Authorization:this.auth.authorizationToken,'Content-Type':'application/json'},body:JSON.stringify(data)},{retry:retry&&safe,consume:r=>r.json()});}
 async put(name,bytes){if(!validObject(name))throw Error('OBJECT_SCOPE');return retryOperation(async()=>{
  // Upload errors require a new B2 URL/token, not a replay to the same upload server.
  const u=await this.call('b2_get_upload_url',{bucketId:this.credentials.bucketId},{retry:false});
  const result=await this.request(u.uploadUrl,{method:'POST',headers:{Authorization:u.authorizationToken,'X-Bz-File-Name':encodeURIComponent(name),'Content-Type':'application/octet-stream','Content-Length':String(bytes.length),'X-Bz-Content-Sha1':digest(bytes,'sha1'),'X-Bz-Server-Side-Encryption':'AES256'},body:bytes},{consume:r=>r.json()});
  if(result.bucketId!==this.credentials.bucketId||result.fileName!==name||Number(result.contentLength)!==bytes.length||result.contentSha1!==digest(bytes,'sha1')||typeof result.fileId!=='string'||!result.fileId)throw Error('UPLOAD_BINDING');
  return {fileId:result.fileId,fileName:name,bytes:bytes.length,sha256:digest(bytes)};
 },this.retryOptions);}
 async get(object){if(!validObject(object.fileName)||!object.fileId)throw Error('DOWNLOAD_BINDING');const result=await this.request(this.api.downloadUrl+'/b2api/v4/b2_download_file_by_id?fileId='+encodeURIComponent(object.fileId),{headers:{Authorization:this.auth.authorizationToken}},{retry:true,consume:async r=>Buffer.from(await r.arrayBuffer())});if(object.bytes!==undefined&&result.length!==object.bytes||object.sha256&&digest(result)!==object.sha256)throw Error('DOWNLOAD_HASH');return result;}
 async versions(){const result=[];let nextFileName,nextFileId;for(let page=0;page<20;page++){const response=await this.call('b2_list_file_versions',{bucketId:this.credentials.bucketId,prefix:'database/',maxFileCount:1000,...(nextFileName?{startFileName:nextFileName,startFileId:nextFileId}:{})});for(const file of response.files??[])if(validObject(file.fileName))result.push(file);if(!response.nextFileName)return result;nextFileName=response.nextFileName;nextFileId=response.nextFileId;}throw Error('BACKUP_LIST_LIMIT');}
 async latest(now=Date.now(),{requireFresh=true}={}){const versions=await this.versions(),markers=versions.filter(x=>x.action==='upload'&&x.fileName.endsWith('/success.json')).sort((a,b)=>b.fileName.localeCompare(a.fileName)||b.uploadTimestamp-a.uploadTimestamp);for(const object of markers){let marker;try{marker=JSON.parse((await this.get(object)).toString());}catch{continue;}const started=Date.parse(marker.snapshotStarted??'');if(validSuccess(marker)&&object.fileName==='database/'+marker.runId+'/success.json'&&Number.isFinite(started)&&started<=now+300000){if(requireFresh&&overdue(marker,now))throw Error('BACKUP_OVERDUE');return marker;}}throw Error('NO_VERIFIED_BACKUP');
 }
 async recordRestore(marker,restore,now=Date.now()){
  if(!validSuccess(marker)||restore?.networkIsolated!==true||restore?.allDigestsMatch!==true||!Number.isInteger(restore.tables)||restore.tables<1||!Number.isInteger(restore.rows)||restore.rows<0)throw Error('RESTORE_EVIDENCE_REQUIRED');
  const updated={...marker,monthlyRestore:restore,lastRestoreAt:new Date(now).toISOString()};
  const object=await this.put('database/'+marker.runId+'/success.json',Buffer.from(JSON.stringify(updated)));await this.get(object);return updated;
 }
 async prune(current,now=Date.now()){if(overdue(current,now))throw Error('FRESH_BACKUP_REQUIRED');const visible=await this.latest(now);if(visible.runId!==current.runId)throw Error('SUCCESS_MARKER_REQUIRED');const candidates=expiredVersions(await this.versions(),current.runId,now);for(const object of candidates)await this.call('b2_delete_file_version',{fileName:object.fileName,fileId:object.fileId});return candidates.length;}
}
