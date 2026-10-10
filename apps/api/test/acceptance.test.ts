import {test} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {admissionDecision,admissionGates,type Admission} from '../src/beta/admission';
import {deploymentFingerprint} from '../src/beta/config';
const rows=(kind:Admission)=>admissionGates[kind].map(gate=>({gate,status:'PASS',evidence_id:randomUUID(),approved_by:randomUUID()}));
for(const kind of Object.keys(admissionGates) as Admission[]){
 for(const gate of admissionGates[kind])test(kind+' cannot admit without '+gate,()=>{const evidence=rows(kind);assert.equal(admissionDecision(kind,evidence.filter(r=>r.gate!==gate),true).accepted,false);assert.equal(admissionDecision(kind,evidence.map(r=>r.gate===gate?{...r,status:'PENDING'}:r),true).accepted,false);});
 test(kind+' binds approvals and refuses client-derived evidence',()=>{const evidence=rows(kind);assert.equal(admissionDecision(kind,evidence,true).accepted,true);assert.equal(admissionDecision(kind,evidence,false).accepted,false);assert.equal(admissionDecision(kind,evidence.map(r=>({...r,approved_by:''})),true).accepted,false);assert.equal(admissionDecision(kind,evidence.map(r=>({...r,evidence_id:''})),true).accepted,false);});
 test(kind+' has deterministic evidence digest and conflicting duplicates deny',()=>{const evidence=rows(kind),a=admissionDecision(kind,evidence,true);assert.equal(a.digest,admissionDecision(kind,[...evidence].reverse(),true).digest);assert.notEqual(a.digest,admissionDecision(kind,evidence,false).digest);assert.equal(admissionDecision(kind,[...evidence,{...evidence[0]!,status:'BLOCKED'}],true).accepted,false);});
}
const deployment={DATABASE_URL:'postgresql://runtime@isolated-db.test/beta',APP_ENV:'staging',BETA_ENVIRONMENT_ID:randomUUID(),BETA_RELEASE_ID:randomUUID(),API_PUBLIC_ORIGIN:'https://beta-api.example.test',WEB_ORIGIN:'https://beta.example.test',B2_BUCKET_NAME:'isolated-beta',STORAGE_ENVIRONMENT:'staging'};
for(const key of ['BETA_ENVIRONMENT_ID','BETA_RELEASE_ID','API_PUBLIC_ORIGIN','WEB_ORIGIN','B2_BUCKET_NAME','STORAGE_ENVIRONMENT','DATABASE_URL'])test('deployment identity changes with '+key,()=>{const patch=key==='DATABASE_URL'?'postgresql://runtime@other-db.test/beta':key.endsWith('_ID')?randomUUID():key.endsWith('ORIGIN')?'https://other.example.test':'other';assert.notEqual(deploymentFingerprint(deployment),deploymentFingerprint({...deployment,[key]:patch}));});
for(const origin of ['http://localhost:3001','https://user:secret@beta.test','https://beta.test?token=secret','https://beta.test/production','https://beta.test#private'])test('fingerprint rejects unsafe origin '+origin,()=>assert.throws(()=>deploymentFingerprint({...deployment,API_PUBLIC_ORIGIN:origin})));
test('production deployment cannot acquire beta fingerprint',()=>assert.throws(()=>deploymentFingerprint({...deployment,APP_ENV:'production'})));

import {alertSummary,auditProjection} from '../src/hardening/projections';
test('external alerts reject raw capabilities and invalid aggregates',()=>{const summary=alertSummary({count:4,available:false,token:'private',filename:'private',objectKey:'private',signedUrl:'https://private',localAssetIdentifier:'private'});assert.deepEqual(summary,{count:4,available:false});assert.deepEqual(alertSummary({count:Infinity,available:'private'}),{});});
test('audit export omits media credentials and preserves approved evidence',()=>{const summary=auditProjection({summary:{before:'PENDING',after:'PASS',approverId:randomUUID(),count:2,token:'private',signedUrl:'private',filename:'private',localAssetIdentifier:'private',reason:'private signed URL'}}).summary;assert.equal(summary.before,'PENDING');assert.equal(summary.count,2);assert.ok(!JSON.stringify(summary).includes('private'));assert.ok(!('reason' in summary));});
