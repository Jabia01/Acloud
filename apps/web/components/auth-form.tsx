'use client';
import { FormEvent, useEffect, useState } from 'react';
import Link from 'next/link';
import {Brand} from './brand';
import {browserDeviceIdentifier,loginDestination,loginRecoveryFields,signInPath,accountLinkToken,expiredAccountLink} from '../lib/login-recovery';
import {PasswordField} from './password-field';
type Mode = 'register' | 'login' | 'forgot-password' | 'reset-password' | 'verify-email' | 'resend-verification';
const paths = { register: 'register', login: 'login', 'forgot-password': 'password/forgot', 'reset-password': 'password/reset', 'verify-email': 'email/verify', 'resend-verification':'email/resend' };
export function AuthForm({ mode }: { mode: Mode }) {
  const [message, setMessage] = useState('');
  const [token, setToken] = useState('');
  const [completed,setCompleted]=useState(false);
  const [expiredLink,setExpiredLink]=useState(false);
  const [pending, setPending] = useState(false);
  const [sessionLimit,setSessionLimit]=useState(false);
  const [checkingSession,setCheckingSession]=useState(mode==='login');
  const [existingSession,setExistingSession]=useState(false);
  const [destination,setDestination]=useState('/dashboard');
  useEffect(()=>{const next=loginDestination(new URLSearchParams(window.location.search).get('next'));setDestination(next);if(mode!=='login')return;const controller=new AbortController();
    void fetch('/api/auth/me',{cache:'no-store',credentials:'same-origin',signal:AbortSignal.any([controller.signal,AbortSignal.timeout(10000)])}).then(r=>{if(r.ok&&!controller.signal.aborted){setExistingSession(true);window.location.replace(next)}}).catch(()=>{}).finally(()=>{if(!controller.signal.aborted)setCheckingSession(false)});
    return()=>controller.abort();
  },[mode]);
  useEffect(() => {
    if (mode === 'reset-password' || mode === 'verify-email') {
      const incomingToken=accountLinkToken(window.location.hash);
      // Strict Mode can replay this effect after the fragment has been removed.
      if(incomingToken)setToken(incomingToken);
      window.history.replaceState(null, '', window.location.pathname);
    }
  }, [mode]);
  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); if(pending||completed)return; setPending(true); setMessage('');
    const form=event.currentTarget;const values = new FormData(form);
    const body: Record<string, unknown> = {};
    if (values.has('email')) body.email = values.get('email');
    if (values.has('password')) body.password = values.get('password');
    if (mode === 'reset-password' || mode === 'verify-email') body.token = token;
    try {
      if (mode === 'login') {
        // Device identity is non-secret; sessions remain in HttpOnly cookies.
        const identifier=browserDeviceIdentifier(localStorage);
        body.signOutOtherSessions=sessionLimit&&values.get('signOutOtherSessions')==='on';
        body.device = { identifier, displayName: 'Web browser', platform: 'web' };
      }
      const response = await fetch(`/api/auth/${paths[mode]}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),signal:AbortSignal.timeout(20000) });
      const result = await response.json();
      if(response.ok&&(mode==='reset-password'||mode==='verify-email')){setCompleted(true);setToken('');form.reset();}
      if((mode==='reset-password'||mode==='verify-email')&&expiredAccountLink(response.status,result.message)){setExpiredLink(true);setToken('');}
      if (response.ok && mode === 'login') { window.location.assign(destination); return; }
      setSessionLimit(loginRecoveryFields(response.status,mode));
      setMessage(result.message || (response.ok ? 'Completed.' : 'Request failed.'));
    } catch { setMessage('Service unavailable.'); }
    finally { setPending(false); }
  }
  const needsEmail = ['register', 'login', 'forgot-password','resend-verification'].includes(mode);
  const needsPassword = ['register', 'login', 'reset-password'].includes(mode);
  return <main className="auth-card"><Brand/><span className="eyebrow">Your Acloud account</span><h1>{mode==='login'?'Welcome back.':mode==='register'?'A place for your memories.':mode==='forgot-password'?'Let’s get you back in.':mode==='reset-password'?'Set your new password.':mode==='resend-verification'?'Get a new verification link.':'Verify your email.'}</h1><p>{mode==='login'?'Sign in to see what’s protected.':'Manage your account access securely.'}</p>
    {checkingSession&&<p role="status">Checking your existing sign-in…</p>}
    {existingSession&&<p><Link href={destination}>Continue with your existing sign-in</Link> · <Link href="/sessions">Manage active sessions</Link></p>}
    {!completed&&<form method="post" onSubmit={submit}>
      {needsEmail && <label>Email<input name="email" type="email" autoComplete="email" required maxLength={254} /></label>}
      {needsPassword && <><PasswordField newPassword={mode!=='login'}/>{mode!=='login'&&<small>At least 12 characters; no symbol or case rules.</small>}</>}
      {sessionLimit&&<fieldset><legend>Make room to sign in</legend><p>If you are still signed in on another browser or device, open Account → Sessions there to end an older session.</p><label><input name="signOutOtherSessions" type="checkbox" required/>Sign out all other sessions for this account and sign in here.</label><p>Other devices will need to sign in again, and active transfers may stop. Your saved backups stay protected. Your password is checked again before anything changes.</p></fieldset>}
      <button disabled={pending || checkingSession || (!needsEmail && !token)}>{pending ? 'Working…' : mode==='login'?'Sign in':mode==='forgot-password'?'Send recovery link':mode==='reset-password'?'Save new password':mode==='resend-verification'?'Send verification link':'Continue'}</button>
    </form>}<p role="status">{message}</p>
    {(mode==='reset-password'||mode==='verify-email')&&!token&&!completed&&<section aria-label="Recover account link"><p>{expiredLink?'This link has expired or has already been used.':'A valid link from your account email is needed.'}</p>{mode==='reset-password'?<Link href={'/forgot-password?next='+encodeURIComponent(destination)}>Request a new recovery link</Link>:<Link href={'/resend-verification?next='+encodeURIComponent(destination)}>Request a new verification link</Link>}</section>}
    {completed&&<section><p>{mode==='reset-password'?'Your previous sign-ins have ended. Use your new password to sign in again.':'Your email is verified. Continue to your account.'}</p><Link href={signInPath(destination)}>Continue to sign in</Link></section>}
    <nav><Link href={signInPath(destination)}>Sign in</Link> · <Link href="/register">Invitation access</Link> · <Link href={'/forgot-password?next='+encodeURIComponent(destination)}>Reset password</Link> · <Link href="/">Home</Link></nav>
  </main>;
}
