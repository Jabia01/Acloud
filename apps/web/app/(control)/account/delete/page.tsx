import {cookies} from 'next/headers';
import {AccountDeletion} from '../../../../components/account-deletion';
import {SESSION_COOKIE} from '../../../../lib/auth-proxy';
export default async function Page(){
 const token=(await cookies()).get(SESSION_COOKIE)?.value;let accountEmail:string|undefined;
 if(token)try{const response=await fetch(new URL('/me',process.env.API_BASE_URL||'http://127.0.0.1:3001'),{headers:{Authorization:`Bearer ${token}`},cache:'no-store',redirect:'error',signal:AbortSignal.timeout(10000)});if(response.ok){const account=await response.json();if(typeof account.email==='string')accountEmail=account.email;}}catch{}
 return <main className="control customer-panel"><h1 id="page-title">Delete account</h1>{accountEmail?<AccountDeletion accountEmail={accountEmail}/>:<p role="alert">Your account could not be verified. Reload or sign in again before requesting deletion.</p>}<p><a href="/account">Back to account</a></p></main>;
}
