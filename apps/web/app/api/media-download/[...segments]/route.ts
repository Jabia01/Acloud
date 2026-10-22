import {cookies} from 'next/headers';
import {SESSION_COOKIE,cookieOptions} from '../../../../lib/auth-proxy';
import {upstreamDownloadPath,downloadNavigationAllowed,authorizeOriginalDownload,DownloadError} from '../../../../lib/media-download';
export const runtime='nodejs';
const headers={'Cache-Control':'private, no-store','Referrer-Policy':'no-referrer','X-Content-Type-Options':'nosniff'};
function failure(message:string,status:number){
 // Only fixed server-owned messages are rendered; no URL, capability or upstream body.
 const body=`<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Acloud download</title><main><h1>Download unavailable</h1><p>${message}</p><p><a href="/photos">Back to saved photos</a> · <a href="/videos">Saved videos</a> · <a href="/login">Sign in</a></p><p>Your saved backup has not been changed.</p><p>If your browser cannot save a download, check free space on this computer. Your Acloud allowance and device storage are separate.</p></main></html>`;
 return new Response(body,{status,headers:{...headers,'Content-Type':'text/html; charset=utf-8','Content-Security-Policy':"default-src 'none'; base-uri 'none'; frame-ancestors 'none'"}});
}
export async function GET(request:Request,{params}:{params:Promise<{segments:string[]}>}){
 const path=upstreamDownloadPath((await params).segments);
 if(!path||new URL(request.url).search)return failure('This download link is invalid.',404);
 if(!downloadNavigationAllowed(request,process.env.WEB_ORIGIN||'http://localhost:3000'))return failure('Open this download from your Acloud library.',403);
 const store=await cookies(),token=store.get(SESSION_COOKIE)?.value;
 if(!token)return failure('Sign in again to download this file.',401);
 try{
  const grant=await authorizeOriginalDownload({path,token,apiBase:process.env.API_BASE_URL||'http://127.0.0.1:3001',storageOrigin:process.env.PREVIEW_STORAGE_ORIGIN||'https://s3.eu-central-003.backblazeb2.com',signal:AbortSignal.any([request.signal,AbortSignal.timeout(10000)])});
  // Each explicit click obtains a fresh grant. File bytes go directly from private
  // storage to the browser, without Vercel buffering or a full-file size limit.
  return new Response(null,{status:303,headers:{...headers,Location:grant.url}});
 }catch(error){
  if(error instanceof DownloadError&&error.status===401)store.set(SESSION_COOKIE,'',{...cookieOptions(),maxAge:0});
  return failure(error instanceof DownloadError?error.message:'The download service is temporarily unavailable. Try again.',error instanceof DownloadError?error.status:503);
 }
}
