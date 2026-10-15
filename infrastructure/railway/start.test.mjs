import {test} from 'node:test';import assert from 'node:assert/strict';import {check} from './start.mjs';
const closed=['CUSTOMER_REGISTRATION_ENABLED','BETA_ENABLED','BETA_ALLOW_REAL_MEDIA','BETA_ALLOW_PAYMENTS','BETA_ALLOW_B2','BETA_ALLOW_FREE_UP_SPACE','BETA_ALLOW_SUPPORT_TOOLS','BILLING_ENABLED','ENABLE_FREE_UP_SPACE','ACCOUNT_DELETION_ENABLED','ACCOUNT_DELETION_EXECUTION_ENABLED','RETENTION_EXECUTION_ENABLED'];
const fixture=()=>({NODE_ENV:'production',APP_ENV:'staging',STORAGE_ENVIRONMENT:'staging',STORAGE_PROVIDER:'backblaze_b2',B2_BUCKET_NAME:'generated-staging',BETA_EXPECTED_BUCKET:'generated-staging',DATABASE_URL:'postgresql://runtime@db.fixture.supabase.co/postgres?sslmode=verify-full',BETA_DATABASE_NAME:'postgres',PORT:'8080',...Object.fromEntries(closed.map(k=>[k,'false']))});
test('closed bound staging API accepted',()=>assert.equal(check(fixture(),'api'),true));
for(const [name,changes]of [['production bucket',{B2_BUCKET_NAME:'acloud-prod-media',BETA_EXPECTED_BUCKET:'acloud-prod-media'}],['unbound bucket',{BETA_EXPECTED_BUCKET:'other'}],['wrong database',{BETA_DATABASE_NAME:'other'}],['unverified TLS',{DATABASE_URL:'postgresql://runtime@db.fixture.supabase.co/postgres?sslmode=require'}],['local database',{DATABASE_URL:'postgresql://runtime@127.0.0.1/postgres?sslmode=verify-full'}],['TLS bypass',{NODE_TLS_REJECT_UNAUTHORIZED:'0'}],['invalid port',{PORT:'0'}]])test('reject '+name,()=>assert.throws(()=>check({...fixture(),...changes},'api')));
for(const flag of closed)test('reject exposure '+flag,()=>assert.throws(()=>check({...fixture(),[flag]:'true'},'api')));
test('migration refuses runtime identity',()=>assert.throws(()=>check({...fixture(),BETA_MIGRATION_ROLE:'migrator'},'migrate')));
test('unknown role rejected',()=>assert.throws(()=>check(fixture(),'other')));

import {mkdtemp,readFile,stat,rm,symlink,chmod,writeFile,readdir} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {writeDatabaseCa} from './start.mjs';
test('CA provisioning survives restart and refreshes certificate privately',async()=>{
 const root=await mkdtemp(join(tmpdir(),'acloud-restart-'));
 try{const dir=join(root,'config');const target=await writeDatabaseCa(dir,'first public CA');
 await writeDatabaseCa(dir,'replacement public CA');
 assert.equal(await readFile(target,'utf8'),'replacement public CA');
 assert.equal((await stat(target)).mode&0o777,0o600);
 assert.equal((await stat(dir)).mode&0o777,0o700);
 assert.deepEqual(await readdir(dir),['database-ca.pem']);
 }finally{await rm(root,{recursive:true,force:true});}
});
test('CA provisioning refuses links and insecure paths without touching their contents',async()=>{
 const root=await mkdtemp(join(tmpdir(),'acloud-restart-'));
 try{const dir=join(root,'config');await writeDatabaseCa(dir,'public CA');
 const outside=join(root,'outside');await writeFile(outside,'untouched');
 await rm(join(dir,'database-ca.pem'));await symlink(outside,join(dir,'database-ca.pem'));
 await assert.rejects(writeDatabaseCa(dir,'replacement'),/Unsafe certificate/);
 assert.equal(await readFile(outside,'utf8'),'untouched');
 await rm(join(dir,'database-ca.pem'));await chmod(dir,0o755);
 await assert.rejects(writeDatabaseCa(dir,'replacement'),/Unsafe config/);
 await chmod(dir,0o700);await symlink(dir,join(root,'linked'));
 await assert.rejects(writeDatabaseCa(join(root,'linked'),'replacement'),/Unsafe config/);
 }finally{await rm(root,{recursive:true,force:true});}
});
