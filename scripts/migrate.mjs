import { createHash } from 'node:crypto';
import { readdir, readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import pg from 'pg';

export async function migrate(connectionString = process.env.DATABASE_URL, Client = pg.Client) {
  if (!connectionString) throw new Error('DATABASE_URL is required');
  const client = new Client({ connectionString, connectionTimeoutMillis: 3000, statement_timeout: 10000 });
  try {
    await client.connect();
    await client.query('BEGIN');
    // Transaction-scoped advisory lock prevents concurrent migration runners racing.
    await client.query('SELECT pg_advisory_xact_lock(73491001)');
    await client.query(`CREATE TABLE IF NOT EXISTS schema_migrations (
      name TEXT PRIMARY KEY, checksum TEXT NOT NULL, applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )`);
    const directory = new URL('../apps/api/migrations/', import.meta.url);
    const files = (await readdir(directory)).filter(name => /^\d+_[a-z0-9_]+\.sql$/.test(name)).sort();
    let applied = 0;
    for (const name of files) {
      const sql = await readFile(new URL(name, directory), 'utf8');
      const checksum = createHash('sha256').update(sql).digest('hex');
      const existing = await client.query('SELECT checksum FROM schema_migrations WHERE name = $1', [name]);
      if (existing.rowCount) {
        if (existing.rows[0].checksum !== checksum) throw new Error('Applied migration was modified');
        continue;
      }
      await client.query(sql);
      await client.query('INSERT INTO schema_migrations (name, checksum) VALUES ($1, $2)', [name, checksum]);
      applied++;
    }
    await client.query('COMMIT');
    return applied;
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    throw error;
  } finally {
    await client.end();
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  try { console.info(`Migrations complete: ${await migrate()} applied.`); }
  catch { console.error('Migration failed. Check database availability/configuration and migration history. Details suppressed to protect credentials.'); process.exitCode = 1; }
}
