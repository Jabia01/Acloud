import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { migrate } from '../migrate.mjs';

const files = ['001_foundation.sql', '002_accounts.sql'];
const migrations = await Promise.all(files.map(async name => ({ name, sql: await readFile(new URL(`../../apps/api/migrations/${name}`, import.meta.url), 'utf8') })));
const sql = migrations[0].sql;
const checksum = createHash('sha256').update(sql).digest('hex');

function mockClient(existingChecksum, fails = false) {
  const calls = [];
  class Client {
    async connect() { calls.push('connect'); }
    async end() { calls.push('end'); }
    async query(statement, params) {
      calls.push(statement);
      if (statement.startsWith('SELECT checksum')) return existingChecksum ? { rowCount: 1, rows: [{ checksum: existingChecksum === checksum ? createHash('sha256').update(migrations.find(m => m.name === params[0]).sql).digest('hex') : existingChecksum }] } : { rowCount: 0, rows: [] };
      if (statement === sql && fails) throw new Error('simulated SQL failure');
      if (statement.startsWith('INSERT INTO schema_migrations')) assert.equal(params[1], createHash('sha256').update(migrations.find(m => m.name === params[0]).sql).digest('hex'));
      return { rows: [] };
    }
  }
  return { Client, calls };
}

test('migration locks before applying SQL and commits its checksum atomically', async () => {
  const { Client, calls } = mockClient();
  assert.equal(await migrate('test connection', Client), 2);
  assert.ok(calls.indexOf('BEGIN') < calls.indexOf('SELECT pg_advisory_xact_lock(73491001)'));
  assert.ok(calls.indexOf('SELECT pg_advisory_xact_lock(73491001)') < calls.indexOf(sql));
  assert.deepEqual(calls.slice(-2), ['COMMIT', 'end']);
  assert.ok(!calls.includes('ROLLBACK'));
});
test('matching applied migration is skipped; modified migration fails closed', async () => {
  const matching = mockClient(checksum);
  assert.equal(await migrate('test connection', matching.Client), 0);
  assert.ok(!matching.calls.includes(sql));
  const changed = mockClient('incorrect checksum');
  await assert.rejects(migrate('test connection', changed.Client), /Applied migration was modified/);
  assert.deepEqual(changed.calls.slice(-2), ['ROLLBACK', 'end']);
  assert.ok(!changed.calls.includes('COMMIT'));
});
test('SQL failure rolls back and always closes connection', async () => {
  const { Client, calls } = mockClient(undefined, true);
  await assert.rejects(migrate('test connection', Client), /simulated SQL failure/);
  assert.deepEqual(calls.slice(-2), ['ROLLBACK', 'end']);
  assert.ok(!calls.includes('COMMIT'));
});
