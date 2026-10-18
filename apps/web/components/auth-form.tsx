'use client';
import { FormEvent, useEffect, useState } from 'react';
import Link from 'next/link';
import {Brand} from './brand';
type Mode = 'register' | 'login' | 'forgot-password' | 'reset-password' | 'verify-email';
const paths = { register: 'register', login: 'login', 'forgot-password': 'password/forgot', 'reset-password': 'password/reset', 'verify-email': 'email/verify' };
export function AuthForm({ mode }: { mode: Mode }) {
  const [message, setMessage] = useState('');
  const [token, setToken] = useState('');
  const [pending, setPending] = useState(false);
  useEffect(() => {
    if (mode === 'reset-password' || mode === 'verify-email') {
      const incomingToken = new URLSearchParams(window.location.hash.slice(1)).get('token');
      if (incomingToken) setToken(incomingToken);
      window.history.replaceState(null, '', window.location.pathname);
    }
  }, [mode]);
  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault(); setPending(true); setMessage('');
    const values = new FormData(event.currentTarget);
    const body: Record<string, unknown> = {};
    if (values.has('email')) body.email = values.get('email');
    if (values.has('password')) body.password = values.get('password');
    if (mode === 'reset-password' || mode === 'verify-email') body.token = token;
    try {
      if (mode === 'login') {
        // Device identity is non-secret; sessions remain in HttpOnly cookies.
        let identifier = localStorage.getItem('backup_device_id');
        if (!identifier) {
          const bytes = crypto.getRandomValues(new Uint8Array(16));
          bytes[6] = (bytes[6]! & 0x0f) | 0x40;
          bytes[8] = (bytes[8]! & 0x3f) | 0x80;
          const hex = Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join('');
          identifier = `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
          localStorage.setItem('backup_device_id', identifier);
        }
        body.device = { identifier, displayName: 'Web browser', platform: 'web' };
      }
      const response = await fetch(`/api/auth/${paths[mode]}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
      const result = await response.json();
      if (response.ok && mode === 'login') { window.location.assign('/dashboard'); return; }
      setMessage(result.message || (response.ok ? 'Completed.' : 'Request failed.'));
    } catch { setMessage('Service unavailable.'); }
    finally { setPending(false); }
  }
  const needsEmail = ['register', 'login', 'forgot-password'].includes(mode);
  const needsPassword = ['register', 'login', 'reset-password'].includes(mode);
  return <main className="auth-card"><Brand/><span className="eyebrow">Your Acloud account</span><h1>{mode==='login'?'Welcome back.':mode==='register'?'A place for your memories.':mode==='forgot-password'?'Let’s get you back in.':mode==='reset-password'?'Set your new password.':'Verify your email.'}</h1><p>{mode==='login'?'Sign in to see what’s protected.':'Manage your account access securely.'}</p>
    <form method="post" onSubmit={submit}>
      {needsEmail && <label>Email<input name="email" type="email" autoComplete="email" required maxLength={254} /></label>}
      {needsPassword && <label>Password<input name="password" type="password" autoComplete={mode === 'login' ? 'current-password' : 'new-password'} required minLength={mode === 'login' ? 1 : 12} />{mode!=='login'&&<small>At least 12 characters; no symbol or case rules.</small>}</label>}
      {!needsEmail && !token && <p>Open the account email link to continue.</p>}
      <button disabled={pending || (!needsEmail && !token)}>{pending ? 'Working...' : 'Continue'}</button>
    </form><p role="status">{message}</p>
    <nav><Link href="/login">Sign in</Link> · <Link href="/register">Create account</Link> · <Link href="/forgot-password">Reset password</Link> · <Link href="/">Home</Link></nav>
  </main>;
}
