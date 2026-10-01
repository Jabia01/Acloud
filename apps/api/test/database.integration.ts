import 'reflect-metadata';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Pool } from 'pg';
import { Test } from '@nestjs/testing';
import request from 'supertest';
import { AppModule } from '../src/app.module';

test('real PostgreSQL: migrations are repeatable and HTTP health reports database up', async () => {
  // No silent skip: a missing/unreachable database makes this check fail.
  const { migrate } = await import('../../../scripts/migrate.mjs');
  await migrate();
  assert.equal(await migrate(), 0);
  const pool = new Pool({ connectionString: process.env.DATABASE_URL, connectionTimeoutMillis: 2000 });
  try {
    const result = await pool.query("SELECT value FROM foundation_metadata WHERE key = 'schema_stage'");
    assert.equal(result.rows[0].value, 'foundation');
    const module = await Test.createTestingModule({ imports: [AppModule] }).compile();
    const app = module.createNestApplication();
    await app.init();
    try {
      const response = await request(app.getHttpServer()).get('/health').expect(200);
      assert.deepEqual(response.body, { status: 'ok', checks: { api: 'up', database: 'up' } });
    } finally { await app.close(); }
  } finally { await pool.end(); }
});
