import {test} from 'node:test';import assert from 'node:assert/strict';import {failureLocations}from '../ci-integration-annotations.mjs';
test('CI annotations retain failing test source locations without private error contents',()=>{
 const result=failureLocations('test at test/beta.integration.ts:30:954\nBearer generated-private-token\n  at TestContext.<anonymous> (/home/runner/work/Acloud/Acloud/apps/api/test/lifecycle.integration.ts:118:11)');
 assert.deepEqual(result,[{path:'apps/api/test/beta.integration.ts',line:30,column:954},{path:'apps/api/test/lifecycle.integration.ts',line:118,column:11}]);assert.ok(!JSON.stringify(result).includes('private-token'));
});
test('CI annotations reject injected paths and invalid line numbers',()=>{
 assert.deepEqual(failureLocations('test at test/../../private.env:1:1\n::error file=secret::token\ntest at test/example.ts:0:1\ntest at test/example.ts:99999999999999999999:1'),[]);
});
test('CI annotations deduplicate locations and bound the public output',()=>{
 assert.equal(failureLocations('test at test/example.ts:1:2\ntest at test/example.ts:1:2').length,1);
 assert.equal(failureLocations(Array.from({length:100},(_,i)=>`test at test/example.ts:${i+1}:1`).join('\n')).length,20);
});
