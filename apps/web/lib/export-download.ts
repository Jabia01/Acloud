export type ExportFile={sequence:number;category:string;sha256:string;itemCount:number};
export type ExportManifest={exportId:string;schemaVersion:2;generatedAt:string;expiresAt:string;rawMediaIncluded:false;itemCount:number;files:ExportFile[]};
const categories=new Set(['account','lifecycle','devices','sessions','entitlement','subscription','billing','assets','mediaManifests','manifestResources','backupHistory','restoreHistory','accountEvents','privacyRequests','deletionRequests']);
export function verifiedExportManifest(value:unknown,id:string,now=Date.now()):ExportManifest {
 const m=value as ExportManifest;
 if(!m||m.exportId!==id||m.schemaVersion!==2||m.rawMediaIncluded!==false||!Number.isSafeInteger(m.itemCount)||m.itemCount<0||!Number.isFinite(Date.parse(m.generatedAt))||!Number.isFinite(Date.parse(m.expiresAt))||Date.parse(m.expiresAt)<=now||!Array.isArray(m.files)||m.files.length>10000)throw Error('This export is expired or could not be verified. Refresh its status.');
 let total=0;
 for(const [index,f]of m.files.entries()){
  if(!f||f.sequence!==index||!categories.has(f.category)||!Number.isSafeInteger(f.itemCount)||f.itemCount<0||!/^[a-f0-9]{64}$/.test(f.sha256))throw Error('Export file list could not be verified.');
  total+=f.itemCount;if(!Number.isSafeInteger(total))throw Error('Export file list exceeds supported limits.');
 }
 if(total!==m.itemCount)throw Error('Export record totals did not match.');
 return m;
}
export async function verifiedExportRecords(file:ExportFile,cap:{sha256:string;sequence:number;itemCount:number},chunk:{sequence:number;category:string;sha256:string;ndjson:string},bytesAlready=0){
 if(!chunk||typeof chunk.ndjson!=='string'||chunk.sequence!==file.sequence||chunk.category!==file.category||chunk.sha256!==file.sha256||cap.sha256!==file.sha256||cap.sequence!==file.sequence||cap.itemCount!==file.itemCount)throw Error('Export verification failed. Please retry.');
 const raw=new TextEncoder().encode(chunk.ndjson);
 if(!Number.isSafeInteger(bytesAlready)||bytesAlready<0||bytesAlready+raw.byteLength>32*1024*1024)throw Error('This export is too large for one browser download. Download the individual files below.');
 const hash=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',raw)),v=>v.toString(16).padStart(2,'0')).join('');
 if(hash!==file.sha256)throw Error('Export verification failed. Please retry.');
 const records=chunk.ndjson.trim().split('\n').filter(Boolean).map(v=>JSON.parse(v));
 if(records.length!==file.itemCount)throw Error('Export record count did not match. Please retry.');
 return{category:file.category,records,bytes:raw.byteLength};
}
export async function assembleExport(manifest:ExportManifest,load:(file:ExportFile)=>Promise<{cap:{sha256:string;sequence:number;itemCount:number};chunk:{sequence:number;category:string;sha256:string;ndjson:string}}>,progress:(done:number,total:number)=>void=()=>{}){
 verifiedExportManifest(manifest,manifest.exportId);
 const files=[];let total=0;
 for(const f of manifest.files){const {cap,chunk}=await load(f),verified=await verifiedExportRecords(f,cap,chunk,total);total+=verified.bytes;files.push({category:f.category,records:verified.records});progress(files.length,manifest.files.length);}
 return{schemaVersion:2,rawMediaIncluded:false,manifest,files};
}
