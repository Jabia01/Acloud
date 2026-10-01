'use client';
import { FormEvent, useEffect, useState } from 'react';
import Link from 'next/link';
type Mode = 'register' | 'login' | 'forgot-password' | 'reset-password' | 'verify-email';
const paths = { register: 'register', login: 'login', 'forgot-password': 'password/forgot', 'reset-password': 'password/reset', 'verify-email': 'email/verify' };
export function AuthForm({ mode }: { mode: Mode }) {
  const [message, setMessage] = useState('');
  const [token, setToken] = useState('');
  const [pending, setPending] = useState(false);
  useEffect(() => {
    if (mode === 'reset-password' || mode === 'verify-email') {
      setToken(new URLSearchParams(window.location.hash.slice(1)).get('token') || '');
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
    if (mode === 'login') {
      // A non-secret device ID may be stored locally; never store the session here.
      let identifier = localStorage.getItem('backup_device_id');
      if (!identifier) { identifier = crypto.randomUUID(); localStorage.setItem('backup_device_id', identifier); }
      body.device = { identifier, displayName: 'Web browser', platform: 'web' };
    }
    try {
      const response = await fetch(`/api/auth/${paths[mode]}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
      const result = await response.json();
      if (response.ok && mode === 'login') { window.location.assign('/account'); return; }
      setMessage(result.message || (response.ok ? 'Completed.' : 'Request failed.'));
    } catch { setMessage('Service unavailable.'); }
    finally { setPending(false); }
  }
  const needsEmail = ['register', 'login', 'forgot-password'].includes(mode);
  const needsPassword = ['register', 'login', 'reset-password'].includes(mode);
  return <main><h1>{mode.replaceAll('-', ' ')}</h1><p>Development account testing</p>
    <form onSubmit={submit}>
      {needsEmail && <label>Email<input name="email" type="email" autoComplete="email" required maxLength={254} /></label>}
      {needsPassword && <label>Password<input name="password" type="password" autoComplete={mode === 'login' ? 'current-password' : 'new-password'} required minLength={mode === 'login' ? 1 : 12} /><small>At least 12 characters for a new password; no symbol or case rules.</small></label>}
      {!needsEmail && !token && <p>Open the link from the development mailbox to continue.</p>}
      <button disabled={pending || (!needsEmail && !token)}>{pending ? 'Working...' : 'Continue'}</button>
    </form><p role="status">{message}</p>
    <nav><Link href="/login">Sign in</Link> · <Link href="/register">Create account</Link> · <Link href="/forgot-password">Reset password</Link> · <Link href="/">Home</Link></nav>
  </main>;
}
