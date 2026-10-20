import {test} from 'node:test';import assert from 'node:assert/strict';import {createHash} from 'node:crypto';import {verifiedExportRecords} from '../lib/export-download';
const raw='{"record":"generated"}\n',hash=createHash('sha256').update(raw).digest('hex'),file={sequence:0,category:'account',sha256:hash,itemCount:1},cap={sha256:hash},chunk={sequence:0,sha256:hash,ndjson:raw};
test('combined account download verifies integrity and record count',async()=>{assert.deepEqual((await verifiedExportRecords(file,cap,chunk)).records,[{record:'generated'}]);});
test('combined download refuses tampering, swapped chunks and truncated records',async()=>{
 await assert.rejects(verifiedExportRecords(file,cap,{...chunk,ndjson:raw+' '}));
 await assert.rejects(verifiedExportRecords(file,cap,{...chunk,sequence:1}));
 await assert.rejects(verifiedExportRecords({...file,itemCount:2},cap,chunk));
});
test('combined download has a bounded browser-memory budget',async()=>{await assert.rejects(verifiedExportRecords(file,cap,chunk,32*1024*1024),/too large/);});
