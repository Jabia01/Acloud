import {createHash} from 'node:crypto';
export function protectedVersion(r:Record<string,unknown>){return createHash('sha256').update(JSON.stringify([r.storage_provider,r.storage_binding,r.storage_object_key,r.storage_version_id])).digest('hex');}
export function savedThumbnailKey(r:Record<string,unknown>){return r.thumbnail_cloud_version===protectedVersion(r)&&typeof r.thumbnail_sha256==='string'&&/^[a-f0-9]{64}$/.test(r.thumbnail_sha256)?r.thumbnail_cloud_version+':'+r.thumbnail_sha256:null;}
