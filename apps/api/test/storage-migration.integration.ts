import {test} from 'node:test';import assert from 'node:assert/strict';import {randomUUID} from 'node:crypto';import {readFile,readdir} from 'node:fs/promises';import {Pool} from 'pg';
test('additive storage migration preserves legacy verified metadata and quota',async()=>{
 const original=process.env.DATABASE_URL!,schema=`storage_migration_${randomUUID().replaceAll('-','')}`;assert.notEqual(process.env.NODE_ENV,'production');assert.ok(['localhost','127.0.0.1'].includes(new URL(original).hostname));const root=new Pool({connectionString:original});await root.query(`CREATE SCHEMA ${schema}`);const url=new URL(original);url.searchParams.set('options',`-c search_path=${schema}`);const pool=new Pool({connectionString:url.href});
 try{
  const dir=new URL('../migrations/',import.meta.url);for(const f of (await readdir(dir)).filter(f=>/^00[1-7]_/.test(f)).sort())await pool.query(await readFile(new URL(f,dir),'utf8'));
  const user=randomUUID(),asset=randomUUID();await pool.query("INSERT INTO users(id,email,email_normalized,password_hash) VALUES($1,$2,$2,'generated-unused')",[user,`${user}@example.invalid`]);
  await pool.query('UPDATE development_entitlements SET protected_bytes=100,reserved_bytes=10 WHERE user_id=$1',[user]);
  await pool.query("INSERT INTO assets(id,user_id,media_type,expected_size_bytes,expected_checksum,storage_object_key,storage_version_id,verified_size_bytes,status,protected_at) VALUES($1,$2,'test',100,$3,$4,'generated-version',100,'PROTECTED',now())",[asset,user,'a'.repeat(64),`generated/${randomUUID()}`]);
  const before=(await pool.query('SELECT * FROM assets WHERE id=$1',[asset])).rows[0],quota=(await pool.query('SELECT * FROM development_entitlements WHERE user_id=$1',[user])).rows[0];
  await pool.query(await readFile(new URL('008_storage_binding.sql',dir),'utf8'));
  const after=(await pool.query('SELECT * FROM assets WHERE id=$1',[asset])).rows[0];assert.equal(after.storage_provider,'minio');assert.equal(after.storage_binding,null);delete after.storage_provider;delete after.storage_binding;assert.deepEqual(after,before);assert.deepEqual((await pool.query('SELECT * FROM development_entitlements WHERE user_id=$1',[user])).rows[0],quota);
  await assert.rejects(pool.query("UPDATE assets SET storage_provider='backblaze_b2' WHERE id=$1",[asset]));await assert.rejects(pool.query('UPDATE assets SET storage_binding=$2 WHERE id=$1',[asset,'malformed']));
 }finally{await pool.end();await root.query(`DROP SCHEMA IF EXISTS ${schema} CASCADE`);await root.end();}
});
