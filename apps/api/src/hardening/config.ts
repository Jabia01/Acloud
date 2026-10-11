import {betaConfiguration} from '../beta/config';
import {storageConfig} from '../uploads/storage-config';
export type Environment='development'|'test'|'staging'|'production';
const sensitiveFlags=['ENABLE_FREE_UP_SPACE','DISPOSABLE_CLEANUP_CONTEXT','DEV_MAIL_ENABLED','DEV_PHOTOKIT_ENABLED','B2_LIVE_TEST_ENABLED','ALLOW_ADMIN_BOOTSTRAP','MOCK_BILLING_ENABLED','DEBUG_ENDPOINTS_ENABLED','ALLOW_LIVE_STORAGE_TESTS','CUSTOMER_REGISTRATION_ENABLED'];
function required(e:NodeJS.ProcessEnv,name:string){const v=e[name];if(!v||v.length<16||/placeholder|change_me|example|local_dev|test_secret/i.test(v))throw new Error(`Unsafe production setting: ${name}`);return v;}
function origin(v:string|undefined){if(!v)throw new Error('Trusted HTTPS origin required');const u=new URL(v);if(u.protocol!=='https:'||u.username||u.password||u.pathname!=='/'||u.search||u.hash||u.hostname.endsWith('.invalid')||u.hostname==='localhost')throw new Error('Trusted HTTPS origin required');return u.origin;}
export function validateConfiguration(e:NodeJS.ProcessEnv=process.env){
 betaConfiguration(e);
 const mode=e.APP_ENV??e.NODE_ENV??'development';if(!['development','test','staging','production'].includes(mode))throw new Error('Invalid environment');
 if(e.NODE_ENV==='production'&&!['production','staging'].includes(mode))throw new Error('Environment mismatch');
 if(mode==='production'||mode==='staging'){
  if(e.NODE_ENV!=='production')throw new Error('Production runtime required');
  for(const flag of sensitiveFlags)if(e[flag]!==undefined&&e[flag]!=='false')throw new Error(`Unsafe feature flag: ${flag}`);
  if(e.STORAGE_PROVIDER!=='backblaze_b2'||e.STORAGE_ENVIRONMENT!==mode)throw new Error('Production B2 environment required');
  for(const k of ['DATABASE_URL','B2_KEY_ID','B2_APPLICATION_KEY','RATE_LIMIT_KEY_SECRET','MFA_ENCRYPTION_KEY'])required(e,k);
  if(!/^[a-f0-9]{64}$/.test(e.MFA_ENCRYPTION_KEY!))throw new Error('Invalid MFA encryption key');
  const db=new URL(e.DATABASE_URL!);if(!db.password||db.searchParams.get('sslmode')!=='verify-full'||!e.DATABASE_CA_FILE)throw new Error('Verified database TLS required');
  if(e.RATE_LIMIT_BACKEND!=='postgres'||e.SECURE_COOKIES!=='true'||e.ADMIN_MFA_REQUIRED!=='true')throw new Error('Production security controls required');
  const web=origin(e.WEB_ORIGIN),staff=origin(e.STAFF_ORIGIN);origin(e.API_PUBLIC_ORIGIN);
  if(e.CORS_ORIGINS!==web||e.TRUST_PROXY!== 'false'||e.SENSITIVE_LOGGING==='true')throw new Error('Unsafe transport configuration');
  if(!e.STAFF_RP_ID||new URL(staff).hostname!==e.STAFF_RP_ID)throw new Error('Invalid staff RP ID');
  if(!e.SMTP_FROM||/[\r\n]/.test(e.SMTP_FROM))throw new Error('Production email sender required');
  if(e.EMAIL_PROVIDER==='resend'){const key=required(e,'RESEND_API_KEY');if(!/^re_[A-Za-z0-9_-]+$/.test(key))throw new Error('Resend sending key required');}
  else if(e.EMAIL_PROVIDER==='smtp'){if(e.SMTP_TLS!=='true'||!e.SMTP_HOST)throw new Error('Production email required');required(e,'SMTP_PASSWORD');if(!e.SMTP_USER||/[\r\n]/.test(e.SMTP_USER))throw new Error('SMTP identity required');}
  else throw new Error('Production email required');
  storageConfig(e);
  if(e.BILLING_ENABLED==='true'){const key=required(e,'PAYSTACK_SECRET_KEY');if(e.PAYSTACK_ENVIRONMENT!==(mode==='production'?'LIVE':'TEST')||!key.startsWith(mode==='production'?'sk_live_':'sk_test_'))throw new Error('Paystack environment mismatch');}
  if(e.DELETION_COOLDOWN_SECONDS!==undefined&&Number(e.DELETION_COOLDOWN_SECONDS)<86400)throw new Error('Unsafe deletion cooling-off policy');
  if(e.ACCOUNT_DELETION_ENABLED==='true'&&e.PRIVACY_RETENTION_APPROVED!=='true')throw new Error('Approved retention policy required');
 }
 return{mode:mode as Environment,production:mode==='production'||mode==='staging'};
}
export function limitSetting(name:string,fallback:number,max=100000){const n=Number(process.env[name]??fallback);if(!Number.isSafeInteger(n)||n<1||n>max)throw new Error('Invalid resource limit');return n;}
