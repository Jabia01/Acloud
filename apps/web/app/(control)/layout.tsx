import type {ReactNode} from 'react';
import {cookies} from 'next/headers';
import {redirect} from 'next/navigation';
import Link from 'next/link';
import {SESSION_COOKIE} from '../../lib/auth-proxy';
export const dynamic='force-dynamic';
export default async function ControlLayout({children}:{children:ReactNode}) {
 const token=(await cookies()).get(SESSION_COOKIE)?.value;
 if(!token) redirect('/login');
 let status=0;
 try {const r=await fetch(new URL('/me',process.env.API_BASE_URL || 'http://127.0.0.1:3001'),{headers:{Authorization:`Bearer ${token}`},cache:'no-store',redirect:'error',signal:AbortSignal.timeout(10000)});status=r.status;} catch {}
 if(status===401) redirect('/login');
 return <><a className="skip" href="#page-title">Skip to content</a><header className="site-header"><Link href="/dashboard" className="brand">Acloud</Link><nav aria-label="Main">{['Dashboard','Photos','Videos','Devices','Sessions','Account'].map(label=><Link key={label} href={`/${label.toLowerCase()}`}>{label}</Link>)}</nav></header>{status===200 ? children : <main><h1>Service unavailable</h1><p>Your account could not be checked. Please reload to retry.</p></main>}<footer className="support-footer"><h2>Need help?</h2><p>For sign-in, backup or restore questions: <a href="mailto:Support247.acloud@useacloud.com">Support247.acloud@useacloud.com</a></p><p>Privacy requests: <a href="mailto:Privacy247.acloud@useacloud.com">Privacy247.acloud@useacloud.com</a></p><p className="muted">Never send passwords, verification codes or private photos. During staging, contact delivery and support availability are still being verified.</p></footer></>;
}
