'use client';
import React,{useEffect,useRef,useState} from 'react';
import Link from 'next/link';
import {Asset,bytes,date} from '../lib/control';
import {MediaPreview} from './media-preview';
export function libraryGroups(items:Asset[]){
 const groups=new Map<string,Asset[]>();
 for(const item of items){const d=item.protectedAt?new Date(item.protectedAt):null;const key=d&&!Number.isNaN(d.getTime())?d.toLocaleDateString('en-US',{year:'numeric',month:'long',day:'numeric',timeZone:'UTC'}):'Date unavailable';groups.set(key,[...(groups.get(key)||[]),item]);}
 return [...groups];
}
function Thumbnail({asset}:{asset:Asset}){
 const ref=useRef<HTMLSpanElement>(null),[source,setSource]=useState(''),[failed,setFailed]=useState(false);
 useEffect(()=>{
  const controller=new AbortController();let url='',started=false;
  const observer=new IntersectionObserver(entries=>{if(!entries.some(e=>e.isIntersecting)||started)return;started=true;observer.disconnect();
   void(async()=>{try{const r=await fetch(`/api/media-thumbnail/${asset.id}`,{method:'POST',credentials:'same-origin',headers:{'Content-Type':'application/json'},body:'{}',cache:'no-store',signal:controller.signal});if(r.status===401){window.location.replace('/login');return;}if(!r.ok)throw new Error();const blob=await r.blob();if(controller.signal.aborted)return;url=URL.createObjectURL(blob);setSource(url)}catch{if(!controller.signal.aborted)setFailed(true)}})();
  },{rootMargin:'120px'});
  if(ref.current)observer.observe(ref.current);
  return()=>{controller.abort();observer.disconnect();if(url)URL.revokeObjectURL(url)};
 },[asset.id]);
 return <span ref={ref} className="library-thumbnail">{source?<img src={source} alt="" onError={()=>{setSource('');setFailed(true)}}/>:<span className="library-thumbnail-empty"><span aria-hidden="true">{asset.mediaType==='video'?'▷':'▧'}</span><small>{failed?'Preview unavailable':'Loading thumbnail'}</small></span>}</span>;
}
export function PhotoLibrary({items,selecting=false,selected=[],onSelect,busy=false,size=170,onDownload}:{items:Asset[];selecting?:boolean;selected?:string[];onSelect?:(id:string)=>void;busy?:boolean;size?:number;onDownload?:(id:string)=>void}){
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
 {current&&<><header><div><strong>{current.mediaType==='video'?'Video':'Photo'}</strong><p>Saved {date(current.protectedAt)} · {index+1} of {items.length}</p></div><button autoFocus className="secondary-button" onClick={()=>setOpened(null)}>Close</button></header><div className="library-viewer-preview"><Thumbnail key={current.id} asset={current}/></div><div className="library-viewer-actions"><button className="secondary-button" disabled={index===0} onClick={()=>move(-1)}>← Previous</button><button className="secondary-button" disabled={index===items.length-1} onClick={()=>move(1)}>Next →</button><Link href={`/assets/${current.id}`}>File details</Link>{onDownload&&<button disabled={busy} onClick={()=>onDownload(current.id)}>Download original</button>}</div><p className="muted">{current.device?.displayName||'Source device unknown'} · {bytes(current.sizeBytes)} · Verified backup</p><details key={current.id}><summary>Load larger saved preview</summary><p>Downloads the saved file, up to 32 MiB. Your original remains unchanged.</p><MediaPreview key={current.id} id={current.id} type={current.mediaType} size={current.sizeBytes} large inline/></details></>}
 </dialog>
 </div>;
}
