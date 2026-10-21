'use client';
import React,{useEffect,useRef,useState} from 'react';
import Link from 'next/link';
import {Asset,bytes,date} from '../lib/control';
import {useThumbnailCache} from './thumbnail-cache-provider';
import {ThumbnailLoadError} from '../lib/thumbnail-cache';
import {originalDownloadPath} from '../lib/media-download';
import {MediaPreview} from './media-preview';
export function libraryGroups(items:Asset[]){
 const groups=new Map<string,Asset[]>();
 for(const item of items){const d=item.protectedAt?new Date(item.protectedAt):null;const key=d&&!Number.isNaN(d.getTime())?d.toLocaleDateString('en-US',{year:'numeric',month:'long',day:'numeric',timeZone:'UTC'}):'Date unavailable';groups.set(key,[...(groups.get(key)||[]),item]);}
 return [...groups];
}
function Thumbnail({asset}:{asset:Asset}){
 const retries=useRef(0);
 useEffect(()=>{retries.current=0},[asset.id,asset.thumbnailKey]);
 const cache=useThumbnailCache(),ref=useRef<HTMLSpanElement>(null),[source,setSource]=useState(''),[status,setStatus]=useState(0),[revision,setRevision]=useState(0);
 useEffect(()=>{
  let url='',started=false,disposed=false;setSource('');setStatus(0);
  const observer=new IntersectionObserver(entries=>{if(!entries.some(e=>e.isIntersecting)||started)return;started=true;observer.disconnect();
   void(async()=>{try{if(!cache)throw new ThumbnailLoadError(503);const blob=await cache.load(asset.id+':'+(asset.thumbnailKey||'pending'),asset.id);if(disposed)return;url=URL.createObjectURL(blob);setSource(url)}catch(e){if(!disposed){const code=e instanceof ThumbnailLoadError?e.status:503;if(code===401){window.location.replace('/login');return}setStatus(code)}}})();
  },{rootMargin:'120px'});
  if(ref.current)observer.observe(ref.current);
  return()=>{disposed=true;observer.disconnect();if(url)URL.revokeObjectURL(url)};
 },[asset.id,asset.thumbnailKey,cache,revision]);
 useEffect(()=>{if(!status||![404,429,502,503,504].includes(status)||retries.current>=2)return;retries.current++;const timer=setTimeout(()=>setRevision(n=>n+1),status===404?61000:16000);return()=>clearTimeout(timer)},[status]);
 const label=status===404?'Thumbnail not synced yet':status===403?'Preview access restricted':status===409?'Saved preview not ready':status?'Preview temporarily unavailable':'Loading thumbnail';
 return <span ref={ref} className="library-thumbnail">{source?<img src={source} alt="" onError={()=>{setSource('');setStatus(409)}}/>:<span className="library-thumbnail-empty"><span aria-hidden="true">{asset.mediaType==='video'?'▷':'▧'}</span><small>{label}</small></span>}</span>;
}
export function PhotoLibrary({items,selecting=false,selected=[],onSelect,busy=false,size=170}:{items:Asset[];selecting?:boolean;selected?:string[];onSelect?:(id:string)=>void;busy?:boolean;size?:number}){
 const[opened,setOpened]=useState<string|null>(null),dialog=useRef<HTMLDialogElement>(null);
 const current=items.find(a=>a.id===opened),index=items.findIndex(a=>a.id===opened);
 useEffect(()=>{const d=dialog.current;if(current&&!d?.open)d?.showModal();else if(!current&&d?.open)d.close()},[current]);
 const total=items.filter(a=>selected.includes(a.id)).reduce((n,a)=>n+(a.sizeBytes||0),0);
 const move=(delta:number)=>{const a=items[index+delta];if(a)setOpened(a.id)};
 if(!items.length)return <div className="empty-state"><h2>No items to show</h2><p>Try clearing your search, or back up photos and videos from Acloud on your device.</p></div>;
 return <div className="photo-library" style={{'--tile-size':`${size}px`} as React.CSSProperties}>
 {libraryGroups(items).map(([day,assets])=><section className="library-day" key={day} aria-label={`Saved ${day}`}><header><h2>{day}</h2><span>{assets.length} {assets.length===1?'item':'items'}</span></header><ul className="library-grid">{assets.map(a=>{
  const chosen=selected.includes(a.id),disabled=selecting&&(busy||!chosen&&(a.sizeBytes===null||selected.length>=5||total+(a.sizeBytes||0)>500*1024*1024));
  return <li key={a.id} className={chosen?'library-tile selected':'library-tile'}><button type="button" className="library-tile-button" aria-label={`${selecting?'Select':'View'} ${a.mediaType==='video'?'video':'photo'} saved ${date(a.protectedAt)} from ${a.device?.displayName||'unknown device'}`} aria-pressed={selecting?chosen:undefined} disabled={disabled} onClick={()=>selecting?onSelect?.(a.id):setOpened(a.id)}>
   <Thumbnail asset={a}/><span className="library-tile-badge">{a.mediaType==='video'?'▷ Video':a.mediaType==='test'?'Test file':'Photo'}</span>{selecting&&<span className="library-check" aria-hidden="true">{chosen?'✓':''}</span>}
  </button><Link className="library-tile-details" href={`/assets/${a.id}?collection=${a.mediaType==='video'?'videos':'photos'}`} aria-label={`Details for ${a.id.slice(0,8)}`}>Details <span>{bytes(a.sizeBytes)}</span></Link></li>;
 })}</ul></section>)}
 <dialog ref={dialog} className="library-viewer" aria-label="Saved media viewer" onCancel={()=>setOpened(null)} onClose={()=>setOpened(null)} onKeyDown={e=>{if((e.target as HTMLElement).matches('input,select,textarea,video'))return;if(e.key==='ArrowLeft'){e.preventDefault();move(-1)}if(e.key==='ArrowRight'){e.preventDefault();move(1)}}}>
 {current&&<><header><div><strong>{current.mediaType==='video'?'Video':'Photo'}</strong><p>Saved {date(current.protectedAt)} · {index+1} of {items.length}</p></div><button autoFocus className="secondary-button" onClick={()=>setOpened(null)}>Close</button></header><div className="library-viewer-preview"><Thumbnail key={current.id} asset={current}/></div><div className="library-viewer-actions"><button className="secondary-button" disabled={index===0} onClick={()=>move(-1)}>← Previous</button><button className="secondary-button" disabled={index===items.length-1} onClick={()=>move(1)}>Next →</button><Link href={`/assets/${current.id}`}>File details</Link><a href={originalDownloadPath(current.id)} target="_blank" rel="noopener" referrerPolicy="same-origin">Download original</a></div><p className="muted">{current.device?.displayName||'Source device unknown'} · {bytes(current.sizeBytes)} · Verified backup</p><details key={current.id}><summary>Load larger saved preview</summary><p>Downloads the saved file, up to 32 MiB. Your original remains unchanged.</p><MediaPreview key={current.id} id={current.id} type={current.mediaType} size={current.sizeBytes} large inline/></details></>}
 </dialog>
 </div>;
}
