import {cookies} from 'next/headers';
import {NextResponse} from 'next/server';
import {sameOrigin,cookieOptions} from '../../../../lib/auth-proxy';
import {ADMIN_COOKIE,adminRoute,publicStaffLogin} from '../../../../lib/admin';
const reply=(body:unknown,status:number)=>NextResponse.json(body,{status,headers:{'Cache-Control':'private, no-store','Referrer-Policy':'no-referrer'}});
async function handle(request:Request,context:{params:Promise<{segments:string[]}>}){
 const segments=(await context.params).segments,path=adminRoute(request.method,segments,new URL(request.url).search);if(!path)return reply({message:'Not found'},404);
 const login=segments.join('/')==='login',challenge=segments.join('/')==='auth/challenge',publicAuth=login||challenge;if(request.method!=='GET'&&(!sameOrigin(request,process.env.STAFF_ORIGIN||process.env.INTERNAL_WEB_ORIGIN||process.env.WEB_ORIGIN||'http://localhost:3000')||!request.headers.get('content-type')?.startsWith('application/json')))return reply({message:'Request rejected'},403);
 const store=await cookies(),token=store.get(ADMIN_COOKIE)?.value;if(!publicAuth&&!token)return reply({message:'Staff authentication required'},401);
 try{let body:string|undefined;if(request.method==='POST'){body=await request.text();if(Buffer.byteLength(body)>8192)return reply({message:'Invalid input'},400);const b:unknown=JSON.parse(body);if(!b||typeof b!=='object'||Array.isArray(b))return reply({message:'Invalid input'},400);}
 const key=request.headers.get('idempotency-key');if(request.method==='POST'&&!['login','auth/challenge','logout'].includes(segments.join('/'))&&(!key||!/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(key)))return reply({message:'Operation key required'},400);
 const upstream=await fetch(new URL(path,process.env.API_BASE_URL||'http://127.0.0.1:3001'),{method:request.method,headers:{'Content-Type':'application/json',...(!publicAuth&&token?{Authorization:`Bearer ${token}`} : {}),...(key?{'Idempotency-Key':key}:{})},body,cache:'no-store',redirect:'error',signal:AbortSignal.timeout(10000)});
 if(segments.join('/')==='logout'||!publicAuth&&upstream.status===401)store.set(ADMIN_COOKIE,'',{...cookieOptions(),maxAge:0});
 if(!upstream.ok)return reply({message:upstream.status===401?'Staff authentication required':upstream.status===403?'Operation not permitted':upstream.status===429?'Too many requests':upstream.status===409?'Operation conflicts with current state':upstream.status===400?'Invalid request or reason':'Service unavailable'},upstream.status);
 const data:unknown=await upstream.json();if(login){const issued=publicStaffLogin(data);if(!issued)throw new Error();store.set(ADMIN_COOKIE,issued.token,cookieOptions(new Date(issued.expiresAt)));return reply(issued.body,200);}return reply(data,upstream.status);
 }catch{return reply({message:'Service unavailable'},503);}
}
export {handle as GET,handle as POST};
