import {cookies} from 'next/headers';import {NextResponse} from 'next/server';import {SESSION_COOKIE,sameOrigin,cookieOptions} from '../../../../lib/auth-proxy';import {privacyRoute,publicPrivacyResult} from '../../../../lib/privacy';
const reply=(body:unknown,status:number)=>NextResponse.json(body,{status,headers:{'Cache-Control':'private, no-store','Referrer-Policy':'no-referrer'}});
async function handle(request:Request,context:{params:Promise<{segments:string[]}>}){
 const segments=(await context.params).segments,path=privacyRoute(request.method,segments);if(!path||new URL(request.url).search)return reply({message:'Not found'},404);
 if(request.method==='POST'&&(!sameOrigin(request)||!request.headers.get('content-type')?.startsWith('application/json')))return reply({message:'Request rejected'},403);
 const store=await cookies(),token=store.get(SESSION_COOKIE)?.value,publicCapability=['deletion/cancel','deletion/status'].includes(segments.join('/'));if(!token&&!publicCapability)return reply({message:'Sign in required'},401);
 try{let body:string|undefined;if(request.method==='POST'){body=await request.text();if(Buffer.byteLength(body)>8192)return reply({message:'Request too large'},413);const b=JSON.parse(body);if(!b||typeof b!=='object'||Array.isArray(b))return reply({message:'Invalid request'},400);}
 const upstream=await fetch(new URL(path,process.env.API_BASE_URL??'http://127.0.0.1:3001'),{method:request.method,body,headers:{'Content-Type':'application/json',...(token&&!publicCapability?{Authorization:`Bearer ${token}`}:{})},redirect:'error',cache:'no-store',signal:AbortSignal.timeout(10000)});
 if(!upstream.ok)return reply({message:upstream.status===401?'Reauthentication required':upstream.status===403?'Privacy processing awaits policy approval':upstream.status===409?(segments.join('/')==='export'?'You already have active export requests. Open a recent request below or wait for expiry.':'Request conflicts with current state'):'Privacy service unavailable'},upstream.status);
 const data=publicPrivacyResult(segments.join('/'),await upstream.json());if(!data)throw new Error();if(segments.join('/')==='deletion')store.set(SESSION_COOKIE,'',{...cookieOptions(),maxAge:0});return reply(data,upstream.status);
 }catch{return reply({message:'Privacy service unavailable'},503);}
}
export{handle as GET,handle as POST};
