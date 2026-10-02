import {test} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {isProtectedAsset} from '../src/index';
test('transmitted and verifying states never satisfy protected response validation',() => {
  for (const status of ['QUEUED','UPLOADING','UPLOADED','VERIFYING','FAILED','CANCELLED','EXPIRED']) assert.equal(isProtectedAsset({id:randomUUID(),mediaType:'test',status,sizeBytes:100}),false);
});
test('protected response requires valid identity, type and verified positive byte count',() => {
  const valid={id:randomUUID(),mediaType:'test',status:'PROTECTED',sizeBytes:100};
  assert.ok(isProtectedAsset(valid));
  for (const sizeBytes of [null,0,-1,NaN,'100']) assert.equal(isProtectedAsset({...valid,sizeBytes}),false);
  assert.equal(isProtectedAsset({...valid,id:'local-photos-identifier'}),false);
});
