import Link from 'next/link';
import { getApiStatus } from '../../lib/api-status';

export const dynamic = 'force-dynamic';

export default async function Status() {
  const status = await getApiStatus(process.env.API_BASE_URL || 'http://127.0.0.1:3001');
  return <main><h1>Development status</h1><p role="status">API Status: {status}</p>
    <p>Connected means the API and its database are reachable.</p>
    <p>Refresh this page to check again.</p><Link href="/">Home</Link></main>;
}
