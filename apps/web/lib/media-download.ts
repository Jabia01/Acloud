import {safeDownload} from './control';
const uuid=/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i;
export function originalDownloadPath(id:string){if(!uuid.test(id))throw Error('Item unavailable.');return '/api/media-download/assets/'+id;}
export function resourceDownloadPath(manifest:string,resource:string){if(!uuid.test(manifest)||!uuid.test(resource))throw Error('Item unavailable.');return `/api/media-download/manifests/${manifest}/resources/${resource}`;}
export function upstreamDownloadPath(segments:string[]){
 if(segments.length===2&&segments[0]==='assets'&&uuid.test(segments[1]!))return `/assets/${segments[1]}/download`;
 if(segments.length===4&&segments[0]==='manifests'&&uuid.test(segments[1]!)&&segments[2]==='resources'&&uuid.test(segments[3]!))return `/media-manifests/${segments[1]}/resources/${segments[3]}/download`;
 return null;
}
export function downloadNavigationAllowed(request:Request,origin:string){
 const site=request.headers.get('sec-fetch-site');
 if(site==='cross-site'||site==='same-site')return false;
 if(site==='same-origin')return true;
 if(site==='none'&&request.headers.get('sec-fetch-mode')==='navigate')return true;
 try{return new URL(request.headers.get('referer')||'').origin===new URL(origin).origin;}catch{return false;}
}
export class DownloadError extends Error{constructor(public status:number,message:string){super(message);}}
export async function authorizeOriginalDownload({path,token,apiBase,storageOrigin,signal,fetcher=fetch}:{path:string;token:string;apiBase:string;storageOrigin:string;signal:AbortSignal;fetcher?:typeof fetch}){
 if(!/^\/(assets\/[a-f0-9-]{36}|media-manifests\/[a-f0-9-]{36}\/resources\/[a-f0-9-]{36})\/download$/i.test(path))throw new DownloadError(404,'Item unavailable.');
 const response=await fetcher(new URL(path,apiBase),{method:'POST',headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},body:'{}',cache:'no-store',redirect:'error',signal});
 if(!response.ok)throw new DownloadError([401,403,404,409,429].includes(response.status)?response.status:503,
  response.status===401?'Sign in again to download this file.':response.status===403?'Downloads are not available for this account or session. Contact support if this continues.':response.status===404?'This saved file is unavailable.':response.status===409?'This file is not ready to download. Check its backup status.':response.status===429?'Too many requests. Wait a moment and try again.':'The download service is temporarily unavailable. Try again.');
 const grant=safeDownload(await response.json());if(!grant)throw new DownloadError(503,'Download permission could not be confirmed. Try again.');
 const url=new URL(grant.url),origin=new URL(storageOrigin);
 if(origin.username||origin.password||origin.search||origin.hash||!['','/'].includes(origin.pathname)||url.origin!==origin.origin||url.hash)throw new DownloadError(503,'Download destination could not be confirmed.');
 return grant;
}
