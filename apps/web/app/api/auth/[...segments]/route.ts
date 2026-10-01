import { cookies } from 'next/headers';
import { NextResponse } from 'next/server';
import { SESSION_COOKIE, cookieOptions, publicLogin, sameOrigin } from '../../../../lib/auth-proxy';

const routes: Record<string, { method: string; path: string; private?: boolean }> = {
  register: { method: 'POST', path: '/auth/register' }, login: { method: 'POST', path: '/auth/login' }, logout: { method: 'POST', path: '/auth/logout', private: true },
  'email/verify': { method: 'POST', path: '/auth/email/verify' }, 'email/resend': { method: 'POST', path: '/auth/email/resend' },
  'password/forgot': { method: 'POST', path: '/auth/password/forgot' }, 'password/reset': { method: 'POST', path: '/auth/password/reset' },
  me: { method: 'GET', path: '/me', private: true }, sessions: { method: 'GET', path: '/sessions', private: true }, devices: { method: 'GET', path: '/devices', private: true },
};
type Context = { params: Promise<{ segments: string[] }> };
async function handle(request: Request, context: Context) {
  const key = (await context.params).segments.join('/');
  let route = routes[key];
  if (request.method === 'DELETE' && (key === 'sessions' || /^(sessions|devices)\/[0-9a-f-]{36}$/i.test(key))) route = { method: 'DELETE', path: `/${key}`, private: true };
  if (!route || route.method !== request.method) return NextResponse.json({ message: 'Not found' }, { status: 404 });
  if (request.method !== 'GET' && (!sameOrigin(request) || (request.method === 'POST' && !request.headers.get('content-type')?.startsWith('application/json')))) return NextResponse.json({ message: 'Request rejected' }, { status: 403 });
  const store = await cookies();
  const session = store.get(SESSION_COOKIE)?.value;
  if (route.private && !session) return NextResponse.json({ message: 'Authentication required' }, { status: 401 });
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (route.private && session) headers.Authorization = `Bearer ${session}`;
  try {
    let body: string | undefined;
    if (request.method === 'POST') {
      body = await request.text();
      if (Buffer.byteLength(body) > 16384) return NextResponse.json({ message: 'Invalid input' }, { status: 400 });
      JSON.parse(body);
    }
    const upstream = await fetch(new URL(route.path, process.env.API_BASE_URL || 'http://127.0.0.1:3001'), { method: request.method, headers, body, cache: 'no-store', redirect: 'error', signal: AbortSignal.timeout(10000) });
    const data: unknown = await upstream.json();
    if (key === 'login' && upstream.ok) {
      const login = publicLogin(data);
      if (!login) throw new Error('Invalid upstream');
      store.set(SESSION_COOKIE, login.sessionToken, cookieOptions(new Date(login.expiresAt)));
      return NextResponse.json(login.body, { headers: { 'Cache-Control': 'no-store' } });
    }
    if (key === 'logout' || (route.private && upstream.status === 401)) store.set(SESSION_COOKIE, '', { ...cookieOptions(), maxAge: 0 });
    return NextResponse.json(data, { status: upstream.status, headers: { 'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer' } });
  } catch {
    return NextResponse.json({ message: 'Service unavailable' }, { status: 503, headers: { 'Cache-Control': 'no-store' } });
  }
}
export { handle as GET, handle as POST, handle as DELETE };
