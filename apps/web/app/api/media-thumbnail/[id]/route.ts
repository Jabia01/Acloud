import {cookies} from 'next/headers';
import {SESSION_COOKIE,cookieOptions,sameOrigin} from '../../../../lib/auth-proxy';
import {PreviewError} from '../../../../lib/media-preview';
import {loadPrivateThumbnail} from '../../../../lib/media-thumbnail';
export const runtime='nodejs';
export async function POST(request:Request,{params}:{params:Promise<{id:string}>}){
 const headers={'Cache-Control':'private, no-store','Referrer-Policy':'no-referrer','X-Content-Type-Options':'nosniff'};
 const fail=(status:number)=>Response.json({message:'Saved thumbnail unavailable. Open item details for preview options.'},{status,headers});
 if(!sameOrigin(request)||new URL(request.url).search||request.headers.get('content-type')!=='application/json')return fail(403);
 const store=await cookies(),token=store.get(SESSION_COOKIE)?.value;if(!token)return fail(401);
 try{
  const reader=request.body?.getReader();if(!reader)return fail(400);let body='';
  try{while(true){const v=await reader.read();if(v.done)break;body+=new TextDecoder().decode(v.value);if(body.length>2)return fail(400)}}finally{await reader.cancel().catch(()=>{});reader.releaseLock()}
  if(body!=='{}')return fail(400);
  const{id}=await params,data=await loadPrivateThumbnail({id,token,apiBase:process.env.API_BASE_URL||'http://127.0.0.1:3001',signal:AbortSignal.any([request.signal,AbortSignal.timeout(15000)])});
  return new Response(new Uint8Array(data),{headers:{...headers,'Content-Type':'image/jpeg','Content-Length':String(data.length)}});
 }catch(e){const status=e instanceof PreviewError?e.status:503;if(status===401)store.set(SESSION_COOKIE,'',{...cookieOptions(),maxAge:0});return fail(status)}
}
