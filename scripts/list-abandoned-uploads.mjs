// Read-only inventory. No customer-data/object deletion or quota mutation.
import pg from 'pg';
process.loadEnvFile('.env');
const pool=new pg.Pool({connectionString:process.env.DATABASE_URL,connectionTimeoutMillis:3000});
try {
  const rows=await pool.query(`SELECT status,COUNT(*)::int AS count FROM upload_sessions
    WHERE expires_at<=now() AND status NOT IN ('PROTECTED','EXPIRED') GROUP BY status ORDER BY status`);
  console.info(JSON.stringify({abandonedCounts:rows.rows}));
} catch { console.error('Abandoned-upload inventory unavailable; details suppressed.'); process.exitCode=1; }
finally { await pool.end(); }
