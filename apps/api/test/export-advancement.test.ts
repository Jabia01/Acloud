import 'reflect-metadata';import {test} from 'node:test';import assert from 'node:assert/strict';import {advanceExport} from '../src/lifecycle/exports';import {originalDownloadName} from '../src/uploads/download-name';
test('export worker processes a bounded four slices and stops as soon as ready',async()=>{
 let count=0;assert.equal(await advanceExport(async()=>{count++;return true}),true);assert.equal(count,4);
 count=0;assert.equal(await advanceExport(async()=>++count<2),false);assert.equal(count,2);
 count=0;await assert.rejects(advanceExport(async()=>{count++;throw Error('generated')}));assert.equal(count,1);
});
test('original download extension uses a known format; no guessed JPEG and no filename injection',()=>{
 const id='11111111-1111-4111-8111-111111111111';assert.ok(originalDownloadName(id,'image','public.heic').endsWith('.heic'));assert.ok(originalDownloadName(id,'video','com.apple.quicktime-movie').endsWith('.mov'));assert.ok(originalDownloadName(id,'image','unknown').endsWith('.bin'));assert.throws(()=>originalDownloadName('bad\r\nInjected: yes','image'));
});
