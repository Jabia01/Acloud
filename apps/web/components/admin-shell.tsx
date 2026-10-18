import {AdminLifecycle} from './admin-lifecycle';
import {BetaOperations} from './beta-operations';
import {AdminBilling} from './admin-billing';
import React from 'react';
import {cookies} from 'next/headers';
import {redirect} from 'next/navigation';
import Link from 'next/link';
import {ADMIN_COOKIE,Staff,staffSections} from '../lib/admin';
import {AdminPanel} from './admin-panel';
import {AdminFrame} from './admin-frame';
export async function AdminShell({section,id}:{section:string;id?:string}){
 const token=(await cookies()).get(ADMIN_COOKIE)?.value;if(!token)redirect('/admin/login');let status=0,staff:Staff|null=null;try{const r=await fetch(new URL('/internal/me',process.env.API_BASE_URL||'http://127.0.0.1:3001'),{headers:{Authorization:`Bearer ${token}`},cache:'no-store',redirect:'error',signal:AbortSignal.timeout(10000)});status=r.status;if(r.ok)staff=await r.json();}catch{}if(status===401)redirect('/admin/login');
 if(!staff)return <main><h1>Internal operations unavailable</h1><p>Staff access is unavailable. Sign in again or contact the owner about access readiness.</p></main>;
 if(!staffSections(staff).includes(section==='user'?'users':section))return <main><h1>Operation not permitted</h1><Link href="/admin">Overview</Link></main>;
 return <AdminFrame staff={staff} section={section}>{section==='lifecycle'?<AdminLifecycle role={staff.role}/>:section==='beta'?<main><BetaOperations superadmin={staff.role==='SUPERADMIN'}/></main>:section==='billing'?<main><h1 id="admin-title">Internal billing</h1><AdminBilling/></main>:<AdminPanel section={section} id={id} staff={staff}/>} {section==='user'&&staff.role==='SUPERADMIN'&&!staff.ownerReadOnly&&<AdminBilling userId={id}/>}</AdminFrame>;
}
