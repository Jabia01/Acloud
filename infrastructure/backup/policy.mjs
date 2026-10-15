export const BUCKET='acloud-staging-db-backups';
export const SCHEMA='backup_beta';
export const PROJECT='klauhvklmxzvzvqcupyj';
export const IMAGE='postgres@sha256:3645570cccdfa447589da9f57dd740faa29b30938e861289a5574b6ca6b03826';
export const DAY=86400000;
export function runId(date=new Date()){return date.toISOString().replaceAll(':','-');}
export function trustedUrl(value){const u=new URL(value);if(u.protocol!=='https:'||u.username||u.password||!(u.hostname.endsWith('.backblazeb2.com')||u.hostname.endsWith('.backblaze.com')))throw Error('B2_ENDPOINT');return u.href;}
export function validateScope(credentials,allowed){if(credentials.bucketName!==BUCKET||allowed.buckets?.length!==1||allowed.buckets[0].id!==credentials.bucketId||allowed.buckets[0].name!==BUCKET||allowed.namePrefix!=='database/')throw Error('BACKUP_KEY_SCOPE');for(const c of ['listBuckets','readBuckets','listFiles','readFiles','writeFiles'])if(!allowed.capabilities?.includes(c))throw Error('BACKUP_KEY_CAPABILITY');}
export function validateRole(role){if(role.rolname!=='backup_beta_backup'||[role.rolsuper,role.rolcreatedb,role.rolcreaterole,role.rolbypassrls,role.can_write,role.can_create].some(x=>x!==false))throw Error('READ_ONLY_BACKUP_ROLE_REQUIRED');}
const pattern=/^database\/(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}\.\d{3}Z)\/(application\.pgdump\.enc|manifest\.json\.enc|success\.json)$/;
export function validObject(name){return pattern.test(name);}
export function validSuccess(m){return !!m&&m.integrityVerified===true&&m.format==='backup-success-v1'&&m.bucket===BUCKET&&typeof m.runId==='string'&&m.objects?.length===2&&new Set(m.objects.map(x=>x.fileName)).size===2&&m.objects.every(x=>typeof x.fileId==='string'&&x.fileId.length>0&&Number.isInteger(x.bytes)&&x.bytes>28&&/^[a-f0-9]{64}$/.test(x.sha256??'')&&['application.pgdump.enc','manifest.json.enc'].some(n=>x.fileName==='database/'+m.runId+'/'+n));}
export function overdue(marker,now=Date.now()){const time=Date.parse(marker?.snapshotStarted??'');return !validSuccess(marker)||!Number.isFinite(time)||time>now+300000||now-time>26*3600000;}
export function expiredVersions(versions,currentRun,now=Date.now()){
 if(!/^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}\.\d{3}Z$/.test(currentRun))throw Error('RUN_BINDING');
 const candidates=versions.filter(x=>x.action==='upload'&&validObject(x.fileName)&&!x.fileName.startsWith('database/'+currentRun+'/')&&Number.isFinite(x.uploadTimestamp)&&x.uploadTimestamp>0&&x.uploadTimestamp<now-30*DAY);
 if(candidates.some(x=>!x.fileId))throw Error('VERSION_BINDING');return candidates;
}

export function restoreDue(marker,now=Date.now(),days=30){const time=Date.parse(marker?.lastRestoreAt??'');return !Number.isFinite(time)||time>now+300000||now-time>=days*DAY;}
