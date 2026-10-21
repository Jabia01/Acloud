import {test} from 'node:test';import assert from 'node:assert/strict';import {createHash} from 'node:crypto';import {verifiedExportRecords,verifiedExportManifest,assembleExport} from '../lib/export-download';
const raw='{"record":"generated"}\n',hash=createHash('sha256').update(raw).digest('hex'),file={sequence:0,category:'account',sha256:hash,itemCount:1},cap={sha256:hash,sequence:0,itemCount:1},chunk={sequence:0,category:'account',sha256:hash,ndjson:raw};
test('combined account download verifies integrity and record count',async()=>{assert.deepEqual((await verifiedExportRecords(file,cap,chunk)).records,[{record:'generated'}]);});
test('combined download refuses tampering, swapped chunks and truncated records',async()=>{
 await assert.rejects(verifiedExportRecords(file,cap,{...chunk,ndjson:raw+' '}));
 await assert.rejects(verifiedExportRecords(file,cap,{...chunk,sequence:1}));
 await assert.rejects(verifiedExportRecords({...file,itemCount:2},cap,chunk));
});
test('combined download has a bounded browser-memory budget',async()=>{await assert.rejects(verifiedExportRecords(file,cap,chunk,32*1024*1024),/too large/);});

const manifest={exportId:'generated',schemaVersion:2 as const,generatedAt:new Date().toISOString(),expiresAt:new Date(Date.now()+3600000).toISOString(),rawMediaIncluded:false as const,itemCount:1,files:[file]};
test('export manifest binds the selected request, expiry, category and complete sequence/count',()=>{
 assert.equal(verifiedExportManifest(manifest,'generated'),manifest);
 for(const change of [{exportId:'other'},{expiresAt:'invalid'},{expiresAt:'2000-01-01T00:00:00Z'},{schemaVersion:3},{rawMediaIncluded:true},{itemCount:2},{files:[{...file,sequence:1}]},{files:[{...file,category:'private-secret'}]},{files:[file,file]}])assert.throws(()=>verifiedExportManifest({...manifest,...change},'generated'));
});
test('individual download rejects substituted category and authorization sequence/count',async()=>{
 await assert.rejects(verifiedExportRecords(file,cap,{...chunk,category:'billing'}));
 await assert.rejects(verifiedExportRecords(file,{...cap,sequence:1},chunk));
 await assert.rejects(verifiedExportRecords(file,{...cap,itemCount:2},chunk));
});
test('assembled export verifies every file and stops on corruption',async()=>{
 let calls=0;const result=await assembleExport(manifest,async()=>{calls++;return{cap,chunk}});assert.equal(calls,1);assert.equal(result.files[0]?.records[0]?.record,'generated');
 await assert.rejects(assembleExport(manifest,async()=>({cap,chunk:{...chunk,ndjson:'corrupt'}})));
});
