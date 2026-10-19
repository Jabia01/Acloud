import type {ReactNode} from 'react';
import {cookies} from 'next/headers';
import {redirect} from 'next/navigation';
import {CustomerFrame} from '../../components/customer-frame';
import {SESSION_COOKIE} from '../../lib/auth-proxy';
export const dynamic='force-dynamic';
export default async function ControlLayout({children}:{children:ReactNode}) {
 const token=(await cookies()).get(SESSION_COOKIE)?.value;
 if(!token) redirect('/login');
 let status=0;
 try {const r=await fetch(new URL('/me',process.env.API_BASE_URL || 'http://127.0.0.1:3001'),{headers:{Authorization:`Bearer ${token}`},cache:'no-store',redirect:'error',signal:AbortSignal.timeout(10000)});status=r.status;} catch {}
 if(status===401) redirect('/login');
 return <CustomerFrame>{status===200 ? children : <main className="control customer-panel"><h1 id="page-title">Service unavailable</h1><p>Your account could not be checked. Please reload to retry.</p></main>}</CustomerFrame>;
}
