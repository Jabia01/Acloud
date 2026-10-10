import { cookies } from 'next/headers';
import { NextResponse } from 'next/server';
import { SESSION_COOKIE,cookieOptions,sameOrigin } from '../../../../lib/auth-proxy';
import { controlRoute,emptyAuthorizationBody } from '../../../../lib/control';
type Context={params:Promise<{segments:string[]}>};
const reply=(data:unknown,status:number)=>NextResponse.json(data,{status,headers:{'Cache-Control':'private, no-store','Referrer-Policy':'no-referrer'}});
async function handle(request:Request,context:Context) {
  const path=controlRoute(request.method,(await context.params).segments,new URL(request.url).search);
  if(!path) return reply({message:'Not found'},404);
  if(request.method==='POST' && (!sameOrigin(request) || !request.headers.get('content-type')?.startsWith('application/json'))) return reply({message:'Request rejected'},403);
  const store=await cookies(),token=store.get(SESSION_COOKIE)?.value;
  if(!token) return reply({message:'Authentication required'},401);
  try {
    if(request.method==='POST') { const text=await request.text(); if(!emptyAuthorizationBody(text)) return reply({message:'Invalid input'},400); }
    const response=await fetch(new URL(path,process.env.API_BASE_URL || 'http://127.0.0.1:3001'),{method:request.method,headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},...(request.method==='POST' ? {body:'{}'} : {}),cache:'no-store',redirect:'error',signal:AbortSignal.timeout(10000)});
    if(response.status===401) store.set(SESSION_COOKIE,'',{...cookieOptions(),maxAge:0});
    if(!response.ok) return reply({message:response.status===401 ? 'Authentication required' : response.status===404 ? 'Item unavailable' : 'Request unavailable'},response.status);
    return reply(await response.json(),response.status);
  } catch { return reply({message:'Service unavailable'},503); }
}
export {handle as GET,handle as POST};
