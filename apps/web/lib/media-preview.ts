import {createHash} from 'node:crypto';
export const MAX_PREVIEW_BYTES=32*1024*1024;
type Proof={id:string;cloudVersionId:string;expectedSize:number;expectedSha256:string;mediaType:string;resourcePolicy:string};
export class PreviewError extends Error {constructor(public status:number,message:string){super(message)}}
function proof(value:unknown,id:string):Proof{const p=value as Proof;if(!p||p.id!==id||!Number.isSafeInteger(p.expectedSize)||p.expectedSize<1||p.expectedSize>MAX_PREVIEW_BYTES||!['image','video'].includes(p.mediaType)||!/^[a-f0-9]{64}$/.test(p.cloudVersionId)||!/^[a-f0-9]{64}$/.test(p.expectedSha256)||p.resourcePolicy!=='VERIFIED_PREVIEW_RESOURCE')throw new PreviewError(409,'A verified display resource is required.');return p}
const same=(a:Proof,b:Proof)=>['id','cloudVersionId','expectedSize','expectedSha256','mediaType','resourcePolicy'].every(k=>a[k as keyof Proof]===b[k as keyof Proof]);
export function previewMime(data:Uint8Array,type:string){const b=Buffer.from(data);if(type==='image'){if(b.subarray(0,3).equals(Buffer.from([255,216,255])))return 'image/jpeg';if(b.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10])))return 'image/png';if(b.subarray(0,6).toString()==='GIF87a'||b.subarray(0,6).toString()==='GIF89a')return 'image/gif';if(b.subarray(0,4).toString()==='RIFF'&&b.subarray(8,12).toString()==='WEBP')return 'image/webp';if(b.subarray(4,8).toString()==='ftyp'&&['avif','avis'].includes(b.subarray(8,12).toString()))return 'image/avif';}if(type==='video'&&b.subarray(4,8).toString()==='ftyp'&&['isom','iso2','mp41','mp42','avc1','M4V ','qt  '].includes(b.subarray(8,12).toString()))return b.subarray(8,12).toString()==='qt  '?'video/quicktime':'video/mp4';throw new PreviewError(415,'This format needs the Acloud app or an original download to view.');}
export async function loadPrivatePreview({id,token,apiBase,storageOrigin,signal,fetcher=fetch}:{id:string;token:string;apiBase:string;storageOrigin:string;signal:AbortSignal;fetcher?:typeof fetch}){
 if(!/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i.test(id))throw new PreviewError(404,'Item unavailable.');
 const call=async(suffix:string,body?:unknown)=>{const r=await fetcher(new URL(`/restore/assets/${id}/preview${suffix}`,apiBase),{method:body?'POST':'GET',headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},...(body?{body:JSON.stringify(body)}:{}),cache:'no-store',redirect:'error',signal});if(!r.ok)throw new PreviewError([401,403,404,409,429].includes(r.status)?r.status:503,r.status===403?'Preview access is unavailable for this session. Your saved backup is unchanged.':'Saved preview unavailable.');return r.json()};
 const p=proof(await call(''),id),body={cloudVersionId:p.cloudVersionId};
 const grant=await call('/authorize',body);if(!same(p,proof(grant.evidence,id)))throw new PreviewError(409,'Saved version changed.');
 const a=grant.authorization,u=new URL(a?.url),origin=new URL(storageOrigin);
 const remaining=Date.parse(a.expiresAt)-Date.now();
 if(a.method!=='GET'||u.protocol!=='https:'||u.origin!==origin.origin||u.username||u.password||u.hash||!Number.isFinite(remaining)||remaining<=0||remaining>61000)throw new PreviewError(409,'Preview authorization unavailable.');
 const r=await fetcher(u,{method:'GET',cache:'no-store',redirect:'error',signal});
 if(!r.ok||!r.body)throw new PreviewError(503,'Saved file could not be loaded.');
 if(r.headers.has('content-length')&&Number(r.headers.get('content-length'))!==p.expectedSize){await r.body.cancel();throw new PreviewError(409,'Saved size changed.');}
 const reader=r.body.getReader(),chunks:Uint8Array[]=[];let size=0;
 try{while(true){const v=await reader.read();if(v.done)break;size+=v.value.byteLength;if(size>p.expectedSize||size>MAX_PREVIEW_BYTES)throw new PreviewError(413,'Saved file exceeds preview limits.');chunks.push(v.value)}}finally{await reader.cancel().catch(()=>{});reader.releaseLock()}
 const data=Buffer.concat(chunks);if(size!==p.expectedSize||createHash('sha256').update(data).digest('hex')!==p.expectedSha256)throw new PreviewError(409,'Saved file verification failed.');
 if(!same(p,proof(await call('/recheck',body),id)))throw new PreviewError(409,'Saved version changed.');
 return{data,contentType:previewMime(data,p.mediaType)};
}
