import Link from 'next/link';
import {PublicHeader,PublicFooter} from '../../components/brand';
import { getApiStatus } from '../../lib/api-status';

export const dynamic = 'force-dynamic';

export default async function Status() {
  const status = await getApiStatus(process.env.API_BASE_URL || 'http://127.0.0.1:3001');
  return <><PublicHeader/><main className="status-page"><span className="eyebrow">Service status</span><h1>A little clarity on<br/>how things are running.</h1><section className="health-summary"><span className={`health-indicator ${status==='Connected'?'is-healthy':'is-unavailable'}`} aria-hidden="true"/><div><h2>{status==='Connected'?'API and database are reachable':'Unable to confirm service health'}</h2><p role="status">API Status: {status}</p></div></section>
    <p>Connected means the API and its database are reachable.</p>
    <p>Refresh this page to check again.</p><Link href="/">Home</Link></main><PublicFooter/></>;
}
