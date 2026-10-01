'use client';
import { useEffect, useState } from 'react';
import Link from 'next/link';
interface User { email: string; emailVerified: boolean }
interface Session { id: string; current: boolean; lastSeenAt: string; expiresAt: string }
interface Device { id: string; displayName: string; platform: string }
export function Account() {
  const [user, setUser] = useState<User | null>(null);
  const [sessions, setSessions] = useState<Session[]>([]);
  const [devices, setDevices] = useState<Device[]>([]);
  const [message, setMessage] = useState('Checking account...');
  async function load() {
    try {
      const me = await fetch('/api/auth/me', { cache: 'no-store' });
      if (!me.ok) { setUser(null); setMessage(me.status === 401 ? 'Sign in to view your account.' : 'Service unavailable.'); return; }
      setUser(await me.json());
      const [sessionResult, deviceResult] = await Promise.all([fetch('/api/auth/sessions', { cache: 'no-store' }), fetch('/api/auth/devices', { cache: 'no-store' })]);
      if (!sessionResult.ok || !deviceResult.ok) throw new Error('Unavailable');
      setSessions(await sessionResult.json()); setDevices(await deviceResult.json()); setMessage('');
    } catch { setMessage('Service unavailable.'); }
  }
  useEffect(() => { void load(); }, []);
  async function mutate(path: string, method = 'DELETE', body: unknown = {}) {
    try {
      const response = await fetch(`/api/auth/${path}`, { method, headers: { 'Content-Type': 'application/json' }, ...(method === 'POST' ? { body: JSON.stringify(body) } : {}) });
      const result = await response.json(); await load(); setMessage(result.message || (response.ok ? 'Completed.' : 'Request failed.'));
    } catch { setMessage('Service unavailable.'); }
  }
  return <main><h1>Account</h1><p role="status">{message}</p>{user ? <>
    <p>{user.email}</p><p>Email: {user.emailVerified ? 'Verified' : 'Unverified'}</p>
    {!user.emailVerified && <button onClick={() => void mutate('email/resend', 'POST', { email: user.email })}>Resend verification</button>}
    <h2>Active sessions</h2><ul>{sessions.map(session => <li key={session.id}>{session.current ? 'Current session' : 'Other session'} · expires {session.expiresAt} <button onClick={() => void mutate(`sessions/${session.id}`)}>Revoke</button></li>)}</ul>
    <button onClick={() => void mutate('sessions')}>Revoke all other sessions</button>
    <h2>Devices</h2><ul>{devices.map(device => <li key={device.id}>{device.displayName} ({device.platform}) <button onClick={() => void mutate(`devices/${device.id}`)}>Revoke device</button></li>)}</ul>
    <p><button onClick={() => void mutate('logout', 'POST')}>Sign out</button></p>
  </> : <Link href="/login">Sign in</Link>}<p><Link href="/">Home</Link></p></main>;
}
