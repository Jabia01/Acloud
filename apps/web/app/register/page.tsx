import Link from 'next/link';
import {AuthForm} from '../../components/auth-form';
export default function Page(){if(process.env.BETA_ENABLED==='true'||process.env.NODE_ENV==='production')return <main><h1>Invitation required</h1><p>Use the private invitation supplied for your email address. Account activation requires manual approval.</p><Link href="/login">Sign in</Link></main>;return <AuthForm mode="register"/>;}
