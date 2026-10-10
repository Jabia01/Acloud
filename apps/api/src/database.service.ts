import { Injectable, OnApplicationShutdown } from '@nestjs/common';
import { Pool, PoolClient, QueryResultRow } from 'pg';
import {readFileSync} from 'node:fs';

@Injectable()
export class DatabaseService implements OnApplicationShutdown {
  private readonly pool: Pool;

  constructor() {
    if (!process.env.DATABASE_URL) throw new Error('DATABASE_URL is required');
    const connection=new URL(process.env.DATABASE_URL);if(process.env.DATABASE_CA_FILE)connection.searchParams.delete('sslmode');
    this.pool = new Pool({
      connectionString: connection.href,
      ...(process.env.DATABASE_CA_FILE?{ssl:{rejectUnauthorized:true,ca:readFileSync(process.env.DATABASE_CA_FILE,'utf8')}}:{}),
      max: 5, connectionTimeoutMillis: 2000, query_timeout: 2000,
      statement_timeout: 2000, idleTimeoutMillis: 10000,
    });
    // An idle socket failure must not crash the process or print connection details.
    this.pool.on('error', () => {});
  }

  async isReachable(): Promise<boolean> {
    try {
      await this.pool.query('SELECT 1');
      return true;
    } catch {
      return false;
    }
  }

  query<T extends QueryResultRow = QueryResultRow>(sql: string, values?: unknown[]) {
    return this.pool.query<T>(sql, values);
  }

  async transaction<T>(work: (client: PoolClient) => Promise<T>): Promise<T> {
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      const result = await work(client);
      await client.query('COMMIT');
      return result;
    } catch (error) {
      await client.query('ROLLBACK').catch(() => {});
      throw error;
    } finally { client.release(); }
  }

  async onApplicationShutdown(): Promise<void> {
    await this.pool.end();
  }
}
