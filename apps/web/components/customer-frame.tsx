'use client';
import React,{type ReactNode} from 'react';
import Link from 'next/link';
import {usePathname} from 'next/navigation';
import {Brand} from './brand';
const routes=[['/dashboard','Overview','◫'],['/photos','Photos','▧'],['/videos','Videos','▷'],['/devices','Devices','▱'],['/sessions','Sessions','◷'],['/account','Account','◎']] as const;
export function CustomerFrame({children}:{children:ReactNode}){
 const pathname=usePathname()||'/dashboard';
 return <div className="customer-workspace"><a className="skip" href="#page-title">Skip to content</a><aside className="customer-sidebar"><Brand href="/dashboard"/><span className="sidebar-caption">YOUR SPACE</span><nav aria-label="Main">{routes.map(([href,label,icon])=><Link href={href} key={href} aria-current={pathname===href?'page':undefined}><span aria-hidden="true">{icon}</span>{label}</Link>)}</nav><div className="customer-sidebar-note"><span aria-hidden="true">✓</span><strong>Your originals stay yours.</strong><p>Backing up never removes photos or videos from your device.</p><a href="mailto:Support247.acloud@useacloud.com">Contact support ↗</a></div></aside><div className="customer-content"><header className="customer-topbar"><span>Your Acloud <span aria-hidden="true">/</span> <strong>{routes.find(([href])=>href===pathname)?.[1]||'Your account'}</strong></span><Link href="/account" className="access-pill">Manage account ↗</Link></header>{children}<footer className="customer-footer"><div><strong>A little help, when you need it.</strong><p><a href="mailto:Support247.acloud@useacloud.com">Contact support</a> · <a href="mailto:Privacy247.acloud@useacloud.com">Privacy requests</a></p></div><small>Never share passwords, verification codes or private photos with support.</small></footer></div></div>;
}
