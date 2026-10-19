import {createHash} from 'node:crypto';
import {PreviewError} from './media-preview';
const hash=/^[a-f0-9]{64}$/;
export async function loadPrivateThumbnail({id,token,apiBase,signal,fetcher=fetch}:{id:string;token:string;apiBase:string;signal:AbortSignal;fetcher?:typeof fetch}){
 if(!/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i.test(id))throw new PreviewError(404,'Thumbnail unavailable.');
 async function read(path:string){
  const r=await fetcher(new URL(`/restore/assets/${id}/${path}`,apiBase),{headers:{Authorization:`Bearer ${token}`},cache:'no-store',redirect:'error',signal});
  if(!r.ok)throw new PreviewError([401,403,404,409,429].includes(r.status)?r.status:503,'Thumbnail unavailable.');
  if(!r.body)throw new PreviewError(503,'Thumbnail unavailable.');
  const reader=r.body.getReader(),chunks:Uint8Array[]=[];let size=0;
  try{while(true){const v=await reader.read();if(v.done)break;size+=v.value.length;if(size>60000)throw new PreviewError(413,'Thumbnail exceeds limits.');chunks.push(v.value)}}finally{await reader.cancel().catch(()=>{});reader.releaseLock()}
  return JSON.parse(Buffer.concat(chunks).toString());
 }
 const proof=await read('thumbnail-evidence'),t=await read('thumbnail');
 if(proof.id!==id||proof.resourcePolicy!=='VERIFIED_PREVIEW_RESOURCE'||!hash.test(proof.cloudVersionId)||!hash.test(proof.expectedSha256)||t.assetId!==id||t.cloudVersionId!==proof.cloudVersionId||t.sourceSha256!==proof.expectedSha256||!hash.test(t.thumbnailSha256)||t.mimeType!=='image/jpeg'||!Number.isInteger(t.width)||!Number.isInteger(t.height)||t.width<1||t.height<1||t.width>240||t.height>240||typeof t.dataBase64!=='string'||t.dataBase64.length>54616)throw new PreviewError(409,'Thumbnail verification failed.');
 const data=Buffer.from(t.dataBase64,'base64');
 if(data.length<4||data.length>40960||data.toString('base64')!==t.dataBase64||data[0]!==255||data[1]!==216||data.at(-2)!==255||data.at(-1)!==217||createHash('sha256').update(data).digest('hex')!==t.thumbnailSha256)throw new PreviewError(409,'Thumbnail verification failed.');
 return data;
}
