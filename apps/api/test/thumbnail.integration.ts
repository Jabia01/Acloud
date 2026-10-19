import {test} from 'node:test';import assert from 'node:assert/strict';import {randomUUID} from 'node:crypto';import {readFile} from 'node:fs/promises';import pg from 'pg';
test('thumbnail migration enforces byte bounds, owner FK and privacy-deletion purge',async()=>{
 const url=process.env.DATABASE_URL;if(!url||!['localhost','127.0.0.1','db','postgres'].includes(new URL(url).hostname))throw new Error('Generated local database required for thumbnail migration test');
 const c=new pg.Client({connectionString:url}),schema='thumbnail_test_'+randomUUID().replaceAll('-','');await c.connect();
 try{
  await c.query('CREATE SCHEMA '+schema);await c.query('SET search_path TO '+schema);
  await c.query('CREATE TABLE users(id uuid PRIMARY KEY);CREATE TABLE assets(id uuid PRIMARY KEY,user_id uuid REFERENCES users(id),privacy_deleted_at timestamptz)');
  await c.query(await readFile(new URL('../migrations/016_saved_thumbnails.sql',import.meta.url),'utf8'));
  const user=randomUUID(),asset=randomUUID();await c.query('INSERT INTO users VALUES($1)',[user]);await c.query('INSERT INTO assets(id,user_id) VALUES($1,$2)',[asset,user]);
  const insert='INSERT INTO saved_thumbnails(asset_id,user_id,cloud_version_id,source_sha256,thumbnail_sha256,jpeg,width,height) VALUES($1,$2,$3,$3,$3,$4,$5,160)';
  await assert.rejects(c.query(insert,[asset,user,'a'.repeat(64),Buffer.alloc(40961),240]));
  await assert.rejects(c.query(insert,[asset,user,'a'.repeat(64),Buffer.alloc(4),241]));
  await assert.rejects(c.query(insert,[asset,randomUUID(),'a'.repeat(64),Buffer.alloc(4),240]));
  await c.query(insert,[asset,user,'a'.repeat(64),Buffer.from([255,216,255,217]),240]);
  const row=(await c.query('SELECT jpeg,width,height FROM saved_thumbnails WHERE asset_id=$1',[asset])).rows[0];assert.ok(Buffer.isBuffer(row.jpeg));assert.equal(row.jpeg.length,4);
  await c.query('UPDATE assets SET privacy_deleted_at=now() WHERE id=$1',[asset]);assert.equal((await c.query('SELECT count(*)::int n FROM saved_thumbnails')).rows[0].n,0);
 }finally{await c.query('SET search_path TO public');await c.query('DROP SCHEMA IF EXISTS '+schema+' CASCADE');await c.end();}
});
