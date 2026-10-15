import {X509Certificate,randomUUID} from 'node:crypto';
import {mkdir,writeFile,lstat,rename,unlink} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import {pathToFileURL} from 'node:url';
export function check(e,role){
 if(!['api','worker','migrate'].includes(role))throw new Error('Unknown role');
 if(e.NODE_ENV!=='production'||e.APP_ENV!=='staging'||e.STORAGE_ENVIRONMENT!=='staging'||e.STORAGE_PROVIDER!=='backblaze_b2')throw new Error('Staging only');
 if(!e.B2_BUCKET_NAME||e.B2_BUCKET_NAME==='acloud-prod-media'||e.B2_BUCKET_NAME!==e.BETA_EXPECTED_BUCKET)throw new Error('Separate explicitly bound staging bucket required');
 const db=new URL(e.DATABASE_URL);if(!db.hostname.endsWith('.supabase.co')&&!db.hostname.endsWith('.supabase.com'))throw new Error('Expected hosted Supabase database');
 if(db.pathname.slice(1)!==e.BETA_DATABASE_NAME||db.searchParams.get('sslmode')!=='verify-full')throw new Error('Explicit database binding and verified TLS required');
 for(const k of ['CUSTOMER_REGISTRATION_ENABLED','BETA_ENABLED','BETA_ALLOW_REAL_MEDIA','BETA_ALLOW_PAYMENTS','BETA_ALLOW_B2','BETA_ALLOW_FREE_UP_SPACE','BETA_ALLOW_SUPPORT_TOOLS','BILLING_ENABLED','ENABLE_FREE_UP_SPACE','ACCOUNT_DELETION_ENABLED','ACCOUNT_DELETION_EXECUTION_ENABLED','RETENTION_EXECUTION_ENABLED'])if(e[k]!=='false')throw new Error('Closed staging feature required: '+k);
 if(e.NODE_TLS_REJECT_UNAUTHORIZED==='0')throw new Error('TLS verification must remain enabled');
 if(role==='api'){const p=Number(e.PORT??e.API_PORT);if(!Number.isInteger(p)||p<1||p>65535)throw new Error('Invalid API port');}
 if(role==='migrate'&&decodeURIComponent(db.username)!==e.BETA_MIGRATION_ROLE)throw new Error('Separate bound migration role required');
 return true;
}
// A container restart may retain /tmp. Replace the public CA atomically without
// following an existing link or exposing a partially written certificate.
export async function writeDatabaseCa(dir,ca){
 await mkdir(dir,{recursive:true,mode:0o700});const st=await lstat(dir);
 if(!st.isDirectory()||st.isSymbolicLink()||(st.mode&0o077)||st.uid!==process.getuid())throw new Error('Unsafe config directory');
 const target=dir+'/database-ca.pem';
 try{const current=await lstat(target);if(!current.isFile()||current.isSymbolicLink()||(current.mode&0o077)||current.uid!==process.getuid())throw new Error('Unsafe certificate file');}catch(error){if(error.code!=='ENOENT')throw error;}
 const temporary=dir+'/database-ca.'+randomUUID()+'.tmp';
 try{await writeFile(temporary,ca,{mode:0o600,flag:'wx'});await rename(temporary,target);}finally{await unlink(temporary).catch(error=>{if(error.code!=='ENOENT')throw error;});}
 return target;
}
export async function prepare(e,role){check(e,role);const ca=e.DATABASE_CA_PEM??(e.DATABASE_CA_PEM_BASE64?Buffer.from(e.DATABASE_CA_PEM_BASE64,'base64').toString('utf8'):undefined);if(!ca||!ca.includes('-----BEGIN CERTIFICATE-----'))throw new Error('Database CA PEM required');new X509Certificate(ca);
 e.DATABASE_CA_FILE=await writeDatabaseCa('/tmp/backup-railway-config',ca);delete e.DATABASE_CA_PEM;delete e.DATABASE_CA_PEM_BASE64;
 if(role!=='migrate'){if(e.RAILWAY_VOLUME_MOUNT_PATH!=='/data')throw new Error('Persistent /data volume required');for(const name of ['ledger','audit']){await mkdir('/data/'+name,{recursive:true,mode:0o700});const st=await lstat('/data/'+name);if(!st.isDirectory()||st.isSymbolicLink()||(st.mode&0o077))throw new Error('Private persistent directory required');}e.LIFECYCLE_LEDGER_DIR='/data/ledger';e.AUDIT_ARCHIVE_DIR='/data/audit';}
 if(role==='api')e.API_PORT=e.PORT??e.API_PORT;
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
 try{const role=process.argv[2];await prepare(process.env,role);if(role!=='migrate'){const {validateConfiguration}=await import('../../apps/api/dist/hardening/config.js');validateConfiguration();const {lifecyclePolicy}=await import('../../apps/api/dist/lifecycle/policy.js');lifecyclePolicy();}const entry=role==='api'?'apps/api/dist/main.js':role==='worker'?'scripts/supervise-worker.mjs':'scripts/release-migrate.mjs';const child=spawn(process.execPath,[entry,...(role==='migrate'?['--apply']:[])],{stdio:'inherit',env:process.env});for(const signal of ['SIGTERM','SIGINT'])process.once(signal,()=>child.kill(signal));child.once('error',()=>{console.error('Railway process unavailable; details suppressed');process.exitCode=1;});child.once('exit',code=>{process.exitCode=code??1;});}catch{console.error('Railway staging configuration refused; credentials suppressed');process.exitCode=1;}
}
