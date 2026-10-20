// A cache instance belongs to one authenticated frame. No browser disk persistence.
export class ThumbnailLoadError extends Error {constructor(public status:number){super('Thumbnail unavailable')}}
export class ThumbnailCache {
 private entries=new Map<string,{blob?:Blob;retryAt:number;status?:number;promise?:Promise<Blob>}>();
 private active=0;private waiting:(()=>void)[]=[];private disposed=false;private controller=new AbortController();
 constructor(private fetcher:typeof fetch=fetch,private now=()=>Date.now()){}
 clear(){this.disposed=true;this.controller.abort();this.entries.clear();for(const wake of this.waiting.splice(0))wake()}
 async load(key:string,id:string):Promise<Blob>{
  if(this.disposed)throw new ThumbnailLoadError(401);
  const old=this.entries.get(key);
  if(old?.blob){this.entries.delete(key);this.entries.set(key,old);return old.blob}
  if(old?.promise)return old.promise;
  if(old&&old.retryAt>this.now())throw new ThumbnailLoadError(old.status||503);
  const entry:{blob?:Blob;retryAt:number;status?:number;promise?:Promise<Blob>}={retryAt:0};
  entry.promise=this.request(id).then(blob=>{if(!this.disposed){entry.blob=blob;this.trim()}return blob}).catch(error=>{
   entry.status=error instanceof ThumbnailLoadError?error.status:503;
   entry.retryAt=this.now()+([403,404,409].includes(entry.status)?60000:15000);throw error;
  }).finally(()=>{entry.promise=undefined;if(!this.disposed)this.trim()});
  this.entries.set(key,entry);this.trim();return entry.promise;
 }
 private trim(){let bytes=[...this.entries.values()].reduce((n,e)=>n+(e.blob?.size||0),0);for(const [key,e]of this.entries){if(this.entries.size<=128&&bytes<=5*1024*1024)break;if(e.promise)continue;bytes-=e.blob?.size||0;this.entries.delete(key)}}
 private async request(id:string):Promise<Blob>{
  if(this.active>=3)await new Promise<void>(resolve=>this.waiting.push(resolve));else this.active++;
  if(this.disposed)throw new ThumbnailLoadError(401);
  try{
   for(let attempt=0;;attempt++){
    const r=await this.fetcher(`/api/media-thumbnail/${id}`,{method:'POST',credentials:'same-origin',headers:{'Content-Type':'application/json'},body:'{}',cache:'no-store',signal:this.controller.signal});
    if(!r.ok){await r.body?.cancel();if(attempt<2&&[429,502,503,504].includes(r.status)){await this.delay((attempt+1)*1000);continue}throw new ThumbnailLoadError(r.status)}
    if(r.headers.get('content-type')?.split(';')[0]!=='image/jpeg')throw new ThumbnailLoadError(409);
    const reader=r.body?.getReader();if(!reader)throw new ThumbnailLoadError(503);const chunks:Uint8Array[]=[];let size=0;
    try{while(true){const v=await reader.read();if(v.done)break;size+=v.value.length;if(size>40960)throw new ThumbnailLoadError(413);chunks.push(v.value)}}finally{await reader.cancel().catch(()=>{});reader.releaseLock()}
    if(size<4)throw new ThumbnailLoadError(409);return new Blob(chunks as BlobPart[],{type:'image/jpeg'});
   }
  }finally{const next=this.waiting.shift();if(next)next();else this.active--}
 }
 private delay(ms:number){return new Promise<void>((resolve,reject)=>{const signal=this.controller.signal;if(signal.aborted){reject(new ThumbnailLoadError(401));return}const abort=()=>{clearTimeout(timer);reject(new ThumbnailLoadError(401))};const timer=setTimeout(()=>{signal.removeEventListener('abort',abort);resolve()},ms);signal.addEventListener('abort',abort,{once:true})})}
}
