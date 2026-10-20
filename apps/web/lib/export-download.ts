export async function verifiedExportRecords(file:{sequence:number;category:string;sha256:string;itemCount:number},cap:{sha256:string},chunk:{sequence:number;sha256:string;ndjson:string},bytesAlready=0){
 if(typeof chunk.ndjson!=='string'||chunk.sequence!==file.sequence||chunk.sha256!==file.sha256||cap.sha256!==file.sha256)throw Error('Export verification failed. Please retry.');
 const raw=new TextEncoder().encode(chunk.ndjson);
 if(bytesAlready+raw.byteLength>32*1024*1024)throw Error('This export is too large for one browser download. Download the individual metadata files below.');
 const hash=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',raw)),v=>v.toString(16).padStart(2,'0')).join('');
 if(hash!==file.sha256)throw Error('Export verification failed. Please retry.');
 const records=chunk.ndjson.trim().split('\n').filter(Boolean).map(v=>JSON.parse(v));
 if(records.length!==file.itemCount)throw Error('Export record count did not match. Please retry.');
 return{category:file.category,records,bytes:raw.byteLength};
}
