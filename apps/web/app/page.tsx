import Link from 'next/link';

export default function Home() {
  return <main><h1>{process.env.PRODUCT_NAME || 'Acloud'}</h1><p>Development Build</p>
    <p>Engineering foundation for private photo and video backup.</p>
    <p><Link href="/status">View development backend status</Link></p>
    <Link href="/register">Create account</Link> · <Link href="/login">Sign in</Link> · <Link href="/account">Account</Link></main>;
}
