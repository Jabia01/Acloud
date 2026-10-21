import {NextRequest,NextResponse} from 'next/server';
import {securityPolicy} from './lib/security';
export function proxy(request:NextRequest) {
 const nonce=btoa(crypto.randomUUID());
 const policy=securityPolicy(nonce,process.env.NODE_ENV==='production');
 const headers=new Headers(request.headers);
 headers.set('x-nonce',nonce);headers.set('x-login-return',request.nextUrl.pathname);headers.set('Content-Security-Policy',policy);
 const response=NextResponse.next({request:{headers}});
 response.headers.set('Content-Security-Policy',policy);
 response.headers.set('Cache-Control','private, no-store');
 return response;
}
export const config={matcher:['/((?!_next/static|_next/image|favicon.ico).*)']};
