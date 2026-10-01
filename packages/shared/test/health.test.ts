import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isHealthy } from '../src';

test('accepts only a complete healthy response', () => {
  assert.equal(isHealthy({ status: 'ok', checks: { api: 'up', database: 'up' } }), true);
  for (const value of [null, {}, { status: 'ok' }, { status: 'ok', checks: { api: 'up', database: 'down' } }, { status: 'degraded', checks: { api: 'up', database: 'up' } }]) {
    assert.equal(isHealthy(value), false);
  }
});
