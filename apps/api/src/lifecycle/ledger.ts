import { Injectable } from '@nestjs/common';
import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import { mkdir, open, readFile, link, unlink, opendir, lstat } from 'node:fs/promises';
import { isAbsolute, join } from 'node:path';
import { sha } from './policy';
export type ArchivedObject = {
    assetId: string;
    kind: 'OBJECT' | 'MULTIPART';
    provider: string;
    binding: string | null;
    objectKey: string;
    version: string;
};
export type Tombstone = {
    userId: string;
    deletionId: string;
    completedAt: string;
    manifestDigest: string;
    lifecycleVersion: 2;
    identityHmac: string | null;
    identityExpiresAt: string | null;
};
const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
export function canonicalTombstone(t: Tombstone) { if (!uuid.test(t.userId) || !uuid.test(t.deletionId) || !/^[a-f0-9]{64}$/.test(t.manifestDigest) || t.lifecycleVersion !== 2 || !Number.isFinite(Date.parse(t.completedAt)) || t.identityHmac !== null && !/^[a-f0-9]{64}$/.test(t.identityHmac) || t.identityExpiresAt !== null && !Number.isFinite(Date.parse(t.identityExpiresAt)) || Object.keys(t).sort().join(',') !== 'completedAt,deletionId,identityExpiresAt,identityHmac,lifecycleVersion,manifestDigest,userId')
    throw new Error('Invalid deletion tombstone'); return JSON.stringify({ userId: t.userId, deletionId: t.deletionId, completedAt: t.completedAt, manifestDigest: t.manifestDigest, lifecycleVersion: 2, identityHmac: t.identityHmac, identityExpiresAt: t.identityExpiresAt }); }
@Injectable()
export class LifecycleLedger {
    private config() { const directory = process.env.LIFECYCLE_LEDGER_DIR, key = process.env.LIFECYCLE_LEDGER_KEY; if (!directory || !isAbsolute(directory) || !/^[a-f0-9]{64}$/.test(key ?? ''))
        throw new Error('Deletion ledger unavailable'); return { directory, key: Buffer.from(key!, 'hex') }; }
    async publish(t: Tombstone) {
        const raw = canonicalTombstone(t), digest = sha(raw), { directory, key } = this.config();
        await mkdir(directory, { recursive: true, mode: 0o700 });
        const stat = await lstat(directory);
        if (!stat.isDirectory() || stat.isSymbolicLink() || (stat.mode & 0o077)!==0)
            throw new Error('Ledger directory unsafe');
        const destination = join(directory, t.deletionId + '.tombstone');
        try {
            const existing = await this.read(destination, t.deletionId);
            if (canonicalTombstone(existing) !== raw)
                throw new Error('Tombstone conflict');
            return digest;
        }
        catch (e) {
            if ((e as any).code !== 'ENOENT')
                throw e;
        }
        const iv = randomBytes(12), cipher = createCipheriv('aes-256-gcm', key, iv);
        cipher.setAAD(Buffer.from('LIFECYCLE:v2:' + t.deletionId));
        const encrypted = Buffer.concat([cipher.update(raw), cipher.final()]), temporary = join(directory, t.deletionId + '.' + randomBytes(8).toString('hex') + '.tmp'), file = await open(temporary, 'wx', 0o600);
        try {
            await file.writeFile(Buffer.concat([iv, cipher.getAuthTag(), encrypted]));
            await file.sync();
        }
        finally {
            await file.close();
            key.fill(0);
        }
        try {
            await link(temporary, destination);
        }
        catch (e) {
            if ((e as any).code !== 'EEXIST')
                throw e;
            const old = await this.read(destination, t.deletionId);
            if (canonicalTombstone(old) !== raw)
                throw new Error('Tombstone conflict');
        }
        finally {
            await unlink(temporary).catch(() => { });
        }
        const parent = await open(directory, 'r');
        try {
            await parent.sync();
        }
        finally {
            await parent.close();
        }
        return digest;
    }
    async lookup(deletionId:string){if(!uuid.test(deletionId))throw new Error('Invalid deletion identity');const {directory,key}=this.config();key.fill(0);try{return await this.read(join(directory,deletionId+'.tombstone'),deletionId);}catch(e){if((e as any).code==='ENOENT')return null;throw e;}}
    private async read(path: string, id: string) { const stat = await lstat(path); if (!stat.isFile() || stat.isSymbolicLink() || (stat.mode & 0o077)!==0 || stat.size < 28 || stat.size > 4096)
        throw new Error('Ledger item unsafe'); const raw = await readFile(path), { key } = this.config(); try {
        const d = createDecipheriv('aes-256-gcm', key, raw.subarray(0, 12));
        d.setAAD(Buffer.from('LIFECYCLE:v2:' + id));
        d.setAuthTag(raw.subarray(12, 28));
        const t = JSON.parse(Buffer.concat([d.update(raw.subarray(28)), d.final()]).toString()) as Tombstone;
        canonicalTombstone(t);
        if (t.deletionId !== id)
            throw new Error('Ledger identity mismatch');
        return t;
    }
    finally {
        key.fill(0);
    } }
    async *entries() { const { directory, key } = this.config(); key.fill(0); const stat=await lstat(directory);if(!stat.isDirectory()||stat.isSymbolicLink()||(stat.mode&0o077)!==0)throw new Error('Ledger directory unsafe');const entries = await opendir(directory); for await (const file of entries) {
        if (file.name.endsWith('.tmp'))
            continue;
        if (file.isDirectory() && uuid.test(file.name.replace(/\.inventory$/, '')) && file.name.endsWith('.inventory'))
            continue;
        if (!file.isFile() || !uuid.test(file.name.replace(/\.tombstone$/, '')) || !file.name.endsWith('.tombstone'))
            throw new Error('Unexpected ledger entry');
        yield await this.read(join(directory, file.name), file.name.slice(0, -10));
    } }
    private async sealedWrite(directory: string, name: string, value: unknown) { const raw = JSON.stringify(value), { key } = this.config(), iv = randomBytes(12), cipher = createCipheriv('aes-256-gcm', key, iv); cipher.setAAD(Buffer.from('INVENTORY:v1:' + name)); const encrypted = Buffer.concat([cipher.update(raw), cipher.final()]); key.fill(0); const destination = join(directory, name); try {
        const existing = await this.sealedRead(directory, name);
        if (JSON.stringify(existing) !== raw)
            throw new Error('Immutable inventory conflict');
        return;
    }
    catch (e) {
        if ((e as any).code !== 'ENOENT')
            throw e;
    } const temporary = join(directory, name + '.' + randomBytes(8).toString('hex') + '.tmp'), f = await open(temporary, 'wx', 0o600); try {
        await f.writeFile(Buffer.concat([iv, cipher.getAuthTag(), encrypted]));
        await f.sync();
    }
    finally {
        await f.close();
    } try {
        await link(temporary, destination);
    }
    catch (e) {
        if ((e as any).code !== 'EEXIST')
            throw e;
        const existing = await this.sealedRead(directory, name);
        if (JSON.stringify(existing) !== raw)
            throw new Error('Immutable inventory conflict');
    }
    finally {
        await unlink(temporary).catch(() => { });
    } const parent = await open(directory, 'r'); try {
        await parent.sync();
    }
    finally {
        await parent.close();
    } }
    private async sealedRead(directory: string, name: string) { const path = join(directory, name), stat = await lstat(path); if (!stat.isFile() || stat.isSymbolicLink() || (stat.mode & 0o077)!==0 || stat.size < 28 || stat.size > 2 * 1024 * 1024)
        throw new Error('Inventory file unsafe'); const raw = await readFile(path), { key } = this.config(); try {
        const c = createDecipheriv('aes-256-gcm', key, raw.subarray(0, 12));
        c.setAAD(Buffer.from('INVENTORY:v1:' + name));
        c.setAuthTag(raw.subarray(12, 28));
        return JSON.parse(Buffer.concat([c.update(raw.subarray(28)), c.final()]).toString());
    }
    finally {
        key.fill(0);
    } }
    async publishInventory(userId: string, deletionId: string, manifestDigest: string, pages: AsyncIterable<ArchivedObject[]>) { if (!uuid.test(userId) || !uuid.test(deletionId) || !/^[a-f0-9]{64}$/.test(manifestDigest))
        throw new Error('Inventory identity invalid'); const { directory, key } = this.config(); key.fill(0); const target = join(directory, deletionId + '.inventory'); await mkdir(target, { recursive: true, mode: 0o700 }); const stat = await lstat(target); if (!stat.isDirectory() || stat.isSymbolicLink() || (stat.mode & 0o077)!==0)
        throw new Error('Inventory directory unsafe'); let sequence = 0, count = 0, digest = sha('INVENTORY:v1'); for await (const objects of pages) {
        if (objects.length > 100)
            throw new Error('Inventory page bound');
        for (const o of objects)
            this.validateObject(o);
        const page = { userId, deletionId, sequence, objects };
        await this.sealedWrite(target, sequence + '.page', page);
        digest = sha(digest + JSON.stringify(page));
        count += objects.length;
        sequence++;
    } await this.sealedWrite(target, 'header', { userId, deletionId, manifestDigest, pages: sequence, count, digest }); }
    private validateObject(o: ArchivedObject) { if (!o || !uuid.test(o.assetId) || !['OBJECT', 'MULTIPART'].includes(o.kind) || !['minio', 'backblaze_b2'].includes(o.provider) || o.binding !== null && !/^[a-f0-9]{64}$/.test(o.binding) || typeof o.objectKey !== 'string' || o.objectKey.length < 1 || o.objectKey.length > 1024 || typeof o.version !== 'string' || o.version.length < 1 || o.version.length > 1024 || Object.keys(o).sort().join(',') !== 'assetId,binding,kind,objectKey,provider,version')
        throw new Error('Invalid archived object'); }
    async *inventory(t: Tombstone) { const { directory, key } = this.config(); key.fill(0); const target = join(directory, t.deletionId + '.inventory'), stat = await lstat(target); if (!stat.isDirectory() || stat.isSymbolicLink() || (stat.mode & 0o077)!==0)
        throw new Error('Inventory directory unsafe'); const h = await this.sealedRead(target, 'header'); if (h.userId !== t.userId || h.deletionId !== t.deletionId || h.manifestDigest !== t.manifestDigest || !Number.isSafeInteger(h.pages) || h.pages < 0 || h.pages > 1000000 || !Number.isSafeInteger(h.count) || h.count < 0)
        throw new Error('Inventory proof mismatch'); let digest = sha('INVENTORY:v1'), count = 0; for (let n = 0; n < h.pages; n++) {
        const p = await this.sealedRead(target, n + '.page');
        if (p.userId !== t.userId || p.deletionId !== t.deletionId || p.sequence !== n || !Array.isArray(p.objects) || p.objects.length > 100)
            throw new Error('Inventory page mismatch');
        for (const o of p.objects)
            this.validateObject(o);
        digest = sha(digest + JSON.stringify(p));
        count += p.objects.length;
        yield p.objects as ArchivedObject[];
    } if (count !== h.count || digest !== h.digest)
        throw new Error('Inventory digest mismatch'); }
}
