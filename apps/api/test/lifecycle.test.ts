import 'reflect-metadata';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { mkdtemp, rm, readFile, writeFile, readdir, symlink, mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { LifecycleLedger, canonicalTombstone, type Tombstone } from '../src/lifecycle/ledger';
import { lifecyclePolicy, identityHMAC, sha } from '../src/lifecycle/policy';
const generated = (): Tombstone => ({ userId: randomUUID(), deletionId: randomUUID(), completedAt: new Date().toISOString(), manifestDigest: sha('generated-manifest'), lifecycleVersion: 2, identityHmac: null, identityExpiresAt: null });
async function fixture(run: (ledger: LifecycleLedger, path: string) => Promise<void>) { const path = await mkdtemp(join(tmpdir(), 'acl015-ledger-')), previous = { dir: process.env.LIFECYCLE_LEDGER_DIR, key: process.env.LIFECYCLE_LEDGER_KEY }; process.env.LIFECYCLE_LEDGER_DIR = path; process.env.LIFECYCLE_LEDGER_KEY = randomBytes(32).toString('hex'); try {
    await run(new LifecycleLedger(), path);
}
finally {
    if (previous.dir === undefined)
        delete process.env.LIFECYCLE_LEDGER_DIR;
    else
        process.env.LIFECYCLE_LEDGER_DIR = previous.dir;
    if (previous.key === undefined)
        delete process.env.LIFECYCLE_LEDGER_KEY;
    else
        process.env.LIFECYCLE_LEDGER_KEY = previous.key;
    await rm(path, { recursive: true, force: true });
} }
test('ACL015 destructive defaults disabled', () => { const p = lifecyclePolicy({ NODE_ENV: 'production' }); assert.equal(p.execution, false); assert.equal(p.retention, false); assert.equal(p.approved, false); });
test('ACL015 independent ledger required', () => assert.throws(() => lifecyclePolicy({ ACCOUNT_DELETION_EXECUTION_ENABLED: 'true' })));
test('ACL015 production deletion legal approval required', () => assert.throws(() => lifecyclePolicy({ NODE_ENV: 'production', ACCOUNT_DELETION_EXECUTION_ENABLED: 'true', LIFECYCLE_LEDGER_DIR: '/tmp/generated', LIFECYCLE_LEDGER_KEY: randomBytes(32).toString('hex') })));
test('ACL015 production retention legal approval required', () => assert.throws(() => lifecyclePolicy({ NODE_ENV: 'production', RETENTION_EXECUTION_ENABLED: 'true' })));
for (const flag of ['ACCOUNT_DELETION_EXECUTION_ENABLED', 'RETENTION_EXECUTION_ENABLED', 'PRIVACY_RETENTION_APPROVED'])
    test('ACL015 malformed safety flag ' + flag, () => assert.throws(() => lifecyclePolicy({ [flag]: 'yes' })));
for (const [key, value] of [['LIFECYCLE_BATCH_SIZE', '0'], ['LIFECYCLE_BATCH_SIZE', '101'], ['LIFECYCLE_RETRY_LIMIT', '21'], ['DELETION_COOLDOWN_SECONDS', '-1'], ['DELETION_COOLDOWN_SECONDS', '2592001'], ['PRIVACY_EXPORT_BATCH_SIZE', '501'], ['PRIVACY_EXPORT_RETENTION_HOURS', '169'], ['PRIVACY_EXPORT_RETENTION_HOURS', '0'], ['LIFECYCLE_BATCH_SIZE', '1.5'], ['LIFECYCLE_BATCH_SIZE', 'NaN']] as const)
    test('ACL015 unsafe bound ' + key + '=' + value, () => assert.throws(() => lifecyclePolicy({ [key]: value })));
test('ACL015 identity HMAC normalization and key separation', () => { const key = randomBytes(32).toString('hex'), a = identityHMAC(' Generated@Example.invalid ', key); assert.equal(a, identityHMAC('generated@example.invalid', key)); assert.match(a, /^[a-f0-9]{64}$/); assert.notEqual(a, sha('generated@example.invalid')); assert.notEqual(a, identityHMAC('generated@example.invalid', randomBytes(32).toString('hex'))); });
test('ACL015 tombstone rejects PII extra field', () => assert.throws(() => canonicalTombstone({ ...generated(), email: 'generated@example.invalid' } as any)));
for (const [field, value] of [['userId', 'invalid'], ['deletionId', '../escape'], ['manifestDigest', 'bad'], ['completedAt', 'invalid'], ['identityHmac', 'email@example.invalid'], ['lifecycleVersion', 1], ['identityExpiresAt', 'invalid']] as const)
    test('ACL015 invalid tombstone ' + field, () => assert.throws(() => canonicalTombstone({ ...generated(), [field]: value } as any)));
test('ACL015 encrypted independently iterable ledger', () => fixture(async (ledger, path) => { const t = generated(); assert.equal(await ledger.publish(t), sha(canonicalTombstone(t))); const bytes = await readFile(join(path, t.deletionId + '.tombstone')); assert.ok(!bytes.includes(Buffer.from(t.userId))); assert.ok(!bytes.includes(Buffer.from(t.manifestDigest))); const entries = []; for await (const e of new LifecycleLedger().entries())
    entries.push(e); assert.deepEqual(entries, [t]); }));
test('ACL015 retry immutable evidence', () => fixture(async (ledger, path) => { const t = generated(); await ledger.publish(t); const before = await readFile(join(path, t.deletionId + '.tombstone')); await ledger.publish(t); assert.deepEqual(await readFile(join(path, t.deletionId + '.tombstone')), before); assert.equal((await readdir(path)).length, 1); }));
test('ACL015 conflicting proof cannot overwrite', () => fixture(async (ledger) => { const t = generated(); await ledger.publish(t); await assert.rejects(ledger.publish({ ...t, manifestDigest: sha('different') })); const entries = []; for await (const e of ledger.entries())
    entries.push(e); assert.deepEqual(entries, [t]); }));
test('ACL015 concurrent publication single archive', () => fixture(async (ledger, path) => { const t = generated(); await Promise.all(Array.from({ length: 8 }, () => ledger.publish(t))); assert.equal((await readdir(path)).length, 1); const entries = []; for await (const e of ledger.entries())
    entries.push(e); assert.deepEqual(entries, [t]); }));
test('ACL015 ciphertext tamper fails closed', () => fixture(async (ledger, path) => { const t = generated(); await ledger.publish(t); const file = join(path, t.deletionId + '.tombstone'), bytes = await readFile(file); bytes[bytes.length - 1] ^= 1; await writeFile(file, bytes); await assert.rejects(async () => { for await (const e of ledger.entries())
    void e; }); }));
test('ACL015 renamed archive identity fails authentication', () => fixture(async (ledger, path) => { const t = generated(); await ledger.publish(t); await writeFile(join(path, randomUUID() + '.tombstone'), await readFile(join(path, t.deletionId + '.tombstone'))); await assert.rejects(async () => { for await (const e of ledger.entries())
    void e; }); }));
test('ACL015 symlink archive rejected', () => fixture(async (ledger, path) => { const t = generated(), target = join(path, 'outside.tmp'); await writeFile(target, 'generated'); await symlink(target, join(path, t.deletionId + '.tombstone')); await assert.rejects(ledger.publish(t)); await assert.rejects(async () => { for await (const e of ledger.entries())
    void e; }); }));
test('ACL015 unexpected ledger entry rejects replay', () => fixture(async (ledger, path) => { await mkdir(join(path, 'unexpected')); await assert.rejects(async () => { for await (const e of ledger.entries())
    void e; }); }));
test('ACL015 unpublished temporary file ignored', () => fixture(async (ledger, path) => { await writeFile(join(path, 'generated.tmp'), 'incomplete'); let count = 0; for await (const e of ledger.entries()) {
    void e;
    count++;
} assert.equal(count, 0); }));

test('ACL015 independent inventory binds exact user deletion and scope digest',()=>fixture(async(ledger)=>{const t=generated(),object={assetId:randomUUID(),kind:'OBJECT' as const,provider:'minio',binding:null,objectKey:'generated/object',version:'generated-version'};async function* pages(){yield[object];}await ledger.publishInventory(t.userId,t.deletionId,t.manifestDigest,pages());const result=[];for await(const page of ledger.inventory(t))result.push(...page);assert.deepEqual(result,[object]);await assert.rejects(async()=>{for await(const page of ledger.inventory({...t,userId:randomUUID()}))void page;});await assert.rejects(async()=>{for await(const page of ledger.inventory({...t,manifestDigest:sha('different')}))void page;});}));
test('ACL015 inventory ciphertext corruption prevents verified replay',()=>fixture(async(ledger,path)=>{const t=generated();async function* pages(){yield[{assetId:randomUUID(),kind:'OBJECT' as const,provider:'minio',binding:null,objectKey:'generated/object',version:'generated-version'}];}await ledger.publishInventory(t.userId,t.deletionId,t.manifestDigest,pages());const file=join(path,t.deletionId+'.inventory','0.page'),bytes=await readFile(file);bytes[bytes.length-1]^=1;await writeFile(file,bytes);await assert.rejects(async()=>{for await(const page of ledger.inventory(t))void page;});}));

for(const name of ['PRIVACY_EXPORT_KEY','LIFECYCLE_IDENTITY_HMAC_KEY'])test('ACL015 invalid optional encryption key rejected '+name,()=>assert.throws(()=>lifecyclePolicy({[name]:'invalid'})));
