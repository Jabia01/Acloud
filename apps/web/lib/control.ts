export type Asset = {id:string;mediaType:'image'|'video'|'test';status:string;sizeBytes:number|null;protectedAt:string|null;createdAt?:string;captureDate:null;durationSeconds:null;device:{id:string;displayName:string}|null};
export type Inventory = {items:Asset[];nextCursor:string|null};
export type StorageSummary = {quotaBytes:number;protectedBytes:number;reservedBytes:number;remainingBytes:number;assetCount:number;photoCount:number;videoCount:number};
export type BackupSummary = {protectedAssetCount:number;lastProtectedAt:string|null;activeUploads:number;reservedUploads:number;failedUploads:number;staleUploads:number;activeDeviceCount:number};
export type Device = {id:string;displayName:string;platform:string;osVersion:string|null;appVersion:string|null;lastSeenAt:string};
export type Session = {id:string;deviceId:string|null;current:boolean;createdAt:string;lastSeenAt:string;expiresAt:string};
export function bytes(value:number|null) { if(value===null) return 'Unknown'; if(value===0) return '0 B'; const unit=Math.min(4,Math.floor(Math.log(value)/Math.log(1024))); return `${(value/1024**unit).toFixed(unit===0 ? 0 : 1)} ${['B','KiB','MiB','GiB','TiB'][unit]}`; }
export function date(value:string|null) { return value ? new Date(value).toLocaleString('en-US') : 'None yet'; }
export function controlRoute(method:string, segments:string[], search:string) {
  const path=segments.join('/');
  const id='[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}';
  if(method==='GET' && ['assets','storage/summary','backup/summary'].includes(path)) {
    const params=new URLSearchParams(search);
    if(path!=='assets' && params.size) return null;
    if([...params.keys()].some(k=>!['mediaType','limit','cursor'].includes(k)) || [...new Set(params.keys())].some(k=>params.getAll(k).length!==1)) return null;
    return `/${path}${params.size ? `?${params}` : ''}`;
  }
  if(method==='GET' && path==='media-manifests') {const q=new URLSearchParams(search);if([...q.keys()].some(k=>!['limit','cursor'].includes(k))||[...q.keys()].some(k=>q.getAll(k).length!==1))return null;return `/${path}${q.size ? `?${q}`:''}`;}
  if(!search && ((method==='GET' && new RegExp(`^media-manifests/(?:for-asset/)?${id}$`,'i').test(path)) || (method==='POST' && new RegExp(`^media-manifests/${id}/resources/${id}/download$`,'i').test(path))))return `/${path}`;
  if(!search && ((method==='GET' && new RegExp(`^assets/${id}$`,'i').test(path)) || (method==='POST' && new RegExp(`^assets/${id}/download$`,'i').test(path)))) return `/${path}`;
  return null;
}
export function safeDownload(value:unknown): {url:string;expiresAt:string}|null {
  if(!value || typeof value!=='object') return null;
  const v=value as Record<string,unknown>;
  if(v.method!=='GET' || typeof v.url!=='string' || typeof v.expiresAt!=='string') return null;
  try { const u=new URL(v.url); const ttl=Date.parse(v.expiresAt)-Date.now();
    if(u.username || u.password || (u.protocol!=='https:' && !(u.protocol==='http:' && ['localhost','127.0.0.1'].includes(u.hostname))) || ttl<=0 || ttl>61000) return null;
    return {url:v.url,expiresAt:v.expiresAt};
  } catch { return null; }
}
export class SessionExpired extends Error {}
export async function controlRequest<T>(path:string, method='GET', transport:typeof fetch=fetch):Promise<T> {
  const response=await transport(path,{method,cache:'no-store',credentials:'same-origin',...(method==='POST' ? {headers:{'Content-Type':'application/json'},body:'{}'} : {})});
  if(response.status===401) throw new SessionExpired();
  if(!response.ok) throw new Error(response.status===404 ? 'Item unavailable.' : 'Service unavailable. Please try again.');
  return response.json() as Promise<T>;
}

export function emptyAuthorizationBody(text:string):boolean {
 if(text.length>100)return false;
 try {const value:unknown=JSON.parse(text);return value!==null && typeof value==='object' && !Array.isArray(value) && Object.keys(value).length===0;}catch{return false;}
}
