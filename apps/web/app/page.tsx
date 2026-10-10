import Link from 'next/link';

export default function Home() {
  const privateBeta=process.env.BETA_ENABLED==='true'||process.env.NODE_ENV==='production';
  return <main><h1>{process.env.PRODUCT_NAME || 'Acloud'}</h1><p>{privateBeta?'Private beta · access by invitation':'Development build'}</p>
    <p>Engineering foundation for private photo and video backup.</p>
    <p><Link href="/status">View service status</Link></p>
    {!privateBeta&&<><Link href="/register">Create account</Link> · </>} <Link href="/login">Sign in</Link> · <Link href="/dashboard">Dashboard</Link></main>;
}
