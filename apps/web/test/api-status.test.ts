import { test } from 'node:test';
import assert from 'node:assert/strict';
import { getApiStatus } from '../lib/api-status';

test('connects only when HTTP and all backend checks succeed', async () => {
  const fetcher: typeof fetch = async (url, options) => {
    assert.equal(String(url), 'http://localhost:3001/health');
    assert.equal(options?.cache, 'no-store');
    return Response.json({ status: 'ok', checks: { api: 'up', database: 'up' } });
  };
  assert.equal(await getApiStatus('http://localhost:3001', fetcher), 'Connected');
});
test('contains network, HTTP, malformed response and database failures', async () => {
  for (const response of [Response.json({}, { status: 503 }), Response.json({ status: 'ok' }), new Response('invalid json'), Response.json({ status: 'degraded', checks: { api: 'up', database: 'down' } })]) {
    assert.equal(await getApiStatus('http://localhost:3001', async () => response), 'Unavailable');
  }
  assert.equal(await getApiStatus('http://localhost:3001', async () => { throw new Error('network failure'); }), 'Unavailable');
  assert.equal(await getApiStatus('invalid URL'), 'Unavailable');
});
