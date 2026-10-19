import {cookies} from 'next/headers';
import {SESSION_COOKIE,cookieOptions,sameOrigin} from '../../../../lib/auth-proxy';
import {loadPrivatePreview,PreviewError} from '../../../../lib/media-preview';
export const runtime='nodejs';
export const maxDuration=60;
let active=0;
export async function POST(request:Request,{params}:{params:Promise<{id:string}>}){
 const headers={'Cache-Control':'private, no-store','Referrer-Policy':'no-referrer','X-Content-Type-Options':'nosniff'};
 const fail=(message:string,status:number)=>Response.json({message},{status,headers});
 if(!sameOrigin(request)||new URL(request.url).search||request.headers.get('content-type')!=='application/json')return fail('Request rejected.',403);
 const store=await cookies(),token=store.get(SESSION_COOKIE)?.value;if(!token)return fail('Sign in again.',401);
 if(active>=2)return fail('Two previews are already loading. Try again shortly.',429);active++;
 try{if(await request.text()!=='{}')return fail('Invalid input.',400);const{id}=await params;const result=await loadPrivatePreview({id,token,apiBase:process.env.API_BASE_URL||'http://127.0.0.1:3001',storageOrigin:process.env.PREVIEW_STORAGE_ORIGIN||'https://s3.eu-central-003.backblazeb2.com',signal:AbortSignal.any([request.signal,AbortSignal.timeout(45000)])});return new Response(new Uint8Array(result.data),{headers:{...headers,'Content-Type':result.contentType,'Content-Length':String(result.data.length)}})}catch(e){const status=e instanceof PreviewError?e.status:503;if(status===401)store.set(SESSION_COOKIE,'',{...cookieOptions(),maxAge:0});return fail(e instanceof PreviewError?e.message:'Preview unavailable. Please try again.',status)}finally{active--}
}
