const markerEvidence=id=>({integrityVerified:true,objects:['application.pgdump.enc','manifest.json.enc'].map(n=>({fileName:'database/'+id+'/'+n,fileId:'exact-version',bytes:100,sha256:'a'.repeat(64)}))});
import {test} from 'node:test';import assert from 'node:assert/strict';import {BackupStore} from './b2.mjs';import {BUCKET,DAY,runId} from './policy.mjs';
test('retention refuses every delete without a fresh verified current marker',async()=>{const s=new BackupStore({}),calls=[];s.call=async(...args)=>calls.push(args);s.versions=async()=>[];for(const m of [null,{format:'backup-success-v1',bucket:BUCKET,runId:runId(),snapshotStarted:new Date(Date.now()-27*3600000).toISOString()}])await assert.rejects(s.prune(m));const id=runId(),m={format:'backup-success-v1',bucket:BUCKET,runId:id,...markerEvidence(id),snapshotStarted:new Date().toISOString()};s.latest=async()=>({...m,runId:'different'});await assert.rejects(s.prune(m));assert.equal(calls.length,0);});
test('retention sends only exact scoped expired version IDs',async()=>{const s=new BackupStore({}),now=Date.now(),id=runId(),m={format:'backup-success-v1',bucket:BUCKET,runId:id,...markerEvidence(id),snapshotStarted:new Date(now).toISOString()},calls=[];s.latest=async()=>m;s.call=async(...args)=>calls.push(args);s.versions=async()=>[{fileId:'old',fileName:'database/2026-09-01T00-00-00.000Z/application.pgdump.enc',action:'upload',uploadTimestamp:now-31*DAY},{fileId:'media',fileName:'photos/original',action:'upload',uploadTimestamp:now-50*DAY}];assert.equal(await s.prune(m,now),1);assert.deepEqual(calls,[['b2_delete_file_version',{fileName:'database/2026-09-01T00-00-00.000Z/application.pgdump.enc',fileId:'old'}]]);});

test('old verified archives are recoverable while monitoring and retention stay fail closed',async()=>{
 const now=Date.now(),id=runId(new Date(now-48*3600000)),marker={format:'backup-success-v1',bucket:BUCKET,runId:id,...markerEvidence(id),snapshotStarted:new Date(now-48*3600000).toISOString()};
 const store=new BackupStore({});store.versions=async()=>[{fileName:'database/'+id+'/success.json',fileId:'marker',action:'upload',uploadTimestamp:now-48*3600000}];store.get=async()=>Buffer.from(JSON.stringify(marker));
 await assert.rejects(store.latest(now),/BACKUP_OVERDUE/);assert.equal((await store.latest(now,{requireFresh:false})).runId,id);await assert.rejects(store.prune(marker,now));
});
test('recovery refuses malformed evidence and selects newest snapshot rather than newest receipt',async()=>{
 const now=Date.now(),old=runId(new Date(now-48*3600000)),fresh=runId(new Date(now-3600000));
 const make=(id,time)=>({format:'backup-success-v1',bucket:BUCKET,runId:id,...markerEvidence(id),snapshotStarted:new Date(time).toISOString()});
 const values={old:make(old,now-48*3600000),fresh:make(fresh,now-3600000),bad:{...make(fresh,now),objects:[]}};
 const store=new BackupStore({});store.versions=async()=>[{fileId:'bad',fileName:'database/'+fresh+'/success.json',action:'upload',uploadTimestamp:now+1},{fileId:'old',fileName:'database/'+old+'/success.json',action:'upload',uploadTimestamp:now},{fileId:'fresh',fileName:'database/'+fresh+'/success.json',action:'upload',uploadTimestamp:now-3600000}];store.get=async(object)=>Buffer.from(JSON.stringify(values[object.fileId]));
 assert.equal((await store.latest(now)).runId,fresh);
});
test('manual restore persists bound verified evidence and clears restore-overdue state',async()=>{
 const {restoreDue}=await import('./policy.mjs');const now=Date.now(),id=runId(new Date(now-3600000)),marker={format:'backup-success-v1',bucket:BUCKET,runId:id,...markerEvidence(id),snapshotStarted:new Date(now-3600000).toISOString(),lastRestoreAt:new Date(now-32*DAY).toISOString()};
 const store=new BackupStore({});let stored;store.put=async(name,bytes)=>{assert.equal(name,'database/'+id+'/success.json');stored=JSON.parse(bytes);return{fileId:'new-receipt',fileName:name};};store.get=async()=>Buffer.from(JSON.stringify(stored));
 const result=await store.recordRestore(marker,{tables:72,rows:123,networkIsolated:true,allDigestsMatch:true},now);assert.equal(restoreDue(result,now),false);assert.deepEqual(result.objects,marker.objects);assert.equal(result.snapshotStarted,marker.snapshotStarted);
 await assert.rejects(store.recordRestore(marker,{tables:72,rows:123,networkIsolated:false,allDigestsMatch:true},now));
});
