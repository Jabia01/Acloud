'use client';
import React,{useEffect,useRef,useState} from 'react';
import {assembleExport,verifiedExportManifest,verifiedExportRecords,type ExportFile,type ExportManifest} from '../lib/export-download';
import {requestBrowserSave} from '../lib/browser-save';
type Summary={exportId:string;state:string;createdAt:string;expiresAt:string};
const label=(state:string)=>state==='PENDING'||state==='BUILDING'?'Preparing':state==='READY'?'Ready to download':state==='EXPIRED'?'Expired':state==='FAILED'?'Could not prepare export':state;
export function AccountExport(){
 const[history,setHistory]=useState<Summary[]>([]),[historyLoading,setHistoryLoading]=useState(true),[historyError,setHistoryError]=useState('');
 const[exportId,setExport]=useState(''),[state,setState]=useState(''),[manifest,setManifest]=useState<ExportManifest>(),[chunkIndex,setChunkIndex]=useState(0);
 const[message,setMessage]=useState(''),[busy,setBusy]=useState(false),[progress,setProgress]=useState(''),[revision,setRevision]=useState(0);
 const[prepared,setPrepared]=useState<{url:string;filename:string}>();
 const downloadAbort=useRef<AbortController|null>(null);
 const mounted=useRef(false);
 useEffect(()=>{mounted.current=true;return()=>{mounted.current=false;downloadAbort.current?.abort()}},[]);
 async function send(path:string,body?:unknown,signal?:AbortSignal){
  const response=await fetch('/api/privacy/'+path,{method:body===undefined?'GET':'POST',headers:{'Content-Type':'application/json'},...(body===undefined?{}:{body:JSON.stringify(body)}),cache:'no-store',credentials:'same-origin',signal:signal?AbortSignal.any([signal,AbortSignal.timeout(20000)]):AbortSignal.timeout(20000)});
  const data=await response.json();if(response.status===401&&path!=='export'&&mounted.current){setHistory([]);setManifest(undefined);setPrepared(undefined);setExport('')}if(!response.ok)throw Error(response.status===401?(path==='export'?'Your password could not be confirmed. Check it or sign in again.':'Sign in again to manage your data requests.'):data.message||'Export service unavailable. Try again.');return data;
 }
 async function loadHistory(){setHistoryLoading(true);setHistoryError('');try{
  const result=await send('exports');if(!mounted.current)return;
  setHistory(result.items||[]);setExport(current=>current||result.items?.find((item:Summary)=>['PENDING','BUILDING','READY'].includes(item.state))?.exportId||'');
 }catch(error){if(mounted.current)setHistoryError(error instanceof Error?error.message:'Could not load requests.');}finally{if(mounted.current)setHistoryLoading(false)}}
 useEffect(()=>{void loadHistory()},[]);
 useEffect(()=>()=>{if(prepared)URL.revokeObjectURL(prepared.url)},[prepared]);
 useEffect(()=>{if(!manifest)return;const timer=setTimeout(()=>{setState('EXPIRED');setManifest(undefined);setPrepared(undefined)},Math.min(2147483647,Math.max(0,Date.parse(manifest.expiresAt)-Date.now())));return()=>clearTimeout(timer)},[manifest]);
 useEffect(()=>{
  if(!exportId)return;
  const controller=new AbortController();let timer:ReturnType<typeof setTimeout>;
  setManifest(undefined);setPrepared(undefined);setChunkIndex(0);setState('PENDING');setMessage('');
  async function poll(){try{
   const result=await send('exports/'+exportId+'/manifest',undefined,controller.signal);if(controller.signal.aborted)return;
   if(result.state==='READY'){const verified=verifiedExportManifest(result.manifest,exportId);setManifest(verified);setState('READY');setHistory(items=>items.map(item=>item.exportId===exportId?{...item,state:'READY'}:item));return;}
   setState(result.state);setHistory(items=>items.map(item=>item.exportId===exportId?{...item,state:result.state}:item));
   if(['PENDING','BUILDING'].includes(result.state))timer=setTimeout(()=>void poll(),5000);
  }catch(error){if(!controller.signal.aborted){setMessage(error instanceof Error?error.message:'Status unavailable. Try again.');timer=setTimeout(()=>void poll(),15000);}}}
  void poll();return()=>{controller.abort();clearTimeout(timer)};
 },[exportId,revision]);
 async function loadFile(file:ExportFile,signal?:AbortSignal){const path=`exports/${exportId}/chunks/${file.sequence}`,cap=await send(path+'/authorize',{},signal),chunk=await send(path+'/download',{capability:cap.capability},signal);return{cap,chunk};}
 async function download(all:boolean){if(!manifest||busy)return;setBusy(true);setMessage('');setProgress('Preparing your download…');setPrepared(undefined);const controller=new AbortController();downloadAbort.current=controller;try{
  verifiedExportManifest(manifest,exportId);
  if(all){const data=await assembleExport(manifest,file=>loadFile(file,controller.signal),(done,total)=>{if(mounted.current)setProgress(`Preparing file ${done} of ${total}…`)});if(!mounted.current)return;setPrepared({url:URL.createObjectURL(new Blob([JSON.stringify(data)],{type:'application/json'})),filename:'acloud-account-information.json'});}
  else{const file=manifest.files[chunkIndex];if(!file)throw Error('Select an export file.');const {cap,chunk}=await loadFile(file,controller.signal);await verifiedExportRecords(file,cap,chunk);if(!mounted.current)return;setPrepared({url:URL.createObjectURL(new Blob([chunk.ndjson],{type:'application/x-ndjson'})),filename:`acloud-${file.category}-${file.sequence+1}.ndjson`});}
  setMessage('Your verified file is ready. Choose Save file below. Photos and videos are downloaded separately.');
 }catch(error){if(mounted.current)setMessage(error instanceof Error?error.message:'Download unavailable. Your export is unchanged.');}finally{if(mounted.current){setBusy(false);setProgress('')}}}
 return <section aria-labelledby="account-export-title"><h2 id="account-export-title">Download your account information</h2>
 <p>Get your account details and backup records. Original photos and videos are downloaded separately. This does not cancel your subscription or delete anything.</p>
 <form onSubmit={async event=>{event.preventDefault();if(busy)return;const form=event.currentTarget,data=new FormData(form);form.reset();setBusy(true);setMessage('');try{
  const result=await send('export',{password:data.get('password')});if(!mounted.current)return;setExport(result.exportId);setRevision(n=>n+1);await loadHistory();setMessage('Your export is being prepared. Its status updates automatically while this page is open.');
 }catch(error){if(mounted.current){setMessage(error instanceof Error?error.message:'Could not request export.');void loadHistory();}}finally{if(mounted.current)setBusy(false)}}}>
 <label>Re-enter your password<input name="password" type="password" autoComplete="current-password" required disabled={busy}/></label><button disabled={busy}>{busy?'Please wait…':'Request a copy'}</button></form>
 <h3>Recent requests</h3><button className="secondary-button" disabled={historyLoading||busy} onClick={()=>void loadHistory()}>Refresh requests</button>
 {historyLoading&&<p role="status">Loading requests…</p>}{historyError&&<p role="alert">{historyError}</p>}
 {!historyLoading&&!historyError&&history.length===0&&<p>No recent requests.</p>}
 <ul>{history.map(item=><li key={item.exportId}><strong>{label(item.state)}</strong> · Requested {new Date(item.createdAt).toLocaleString()} · Expires {new Date(item.expiresAt).toLocaleString()} <button disabled={busy||item.state==='EXPIRED'} onClick={()=>{setExport(item.exportId);setRevision(n=>n+1)}}>{exportId===item.exportId?'Selected request':'Open request'}</button></li>)}</ul>
 {exportId&&<div aria-live="polite"><p>{label(state)}{['PENDING','BUILDING'].includes(state)&&' — you can leave and return later. Preparation may take a few minutes.'}</p><button className="secondary-button" disabled={busy} onClick={()=>setRevision(n=>n+1)}>Refresh status</button></div>}
 {state==='EXPIRED'&&<p>Request a new copy above. Your original backups have not changed.</p>}
 {state==='FAILED'&&<p>Try requesting another copy, or contact privacy support if this continues.</p>}
 {manifest&&<div><p>{manifest.itemCount.toLocaleString()} records · Available until {new Date(manifest.expiresAt).toLocaleString()}</p>
 <button disabled={busy} onClick={()=>void download(true)}>Prepare account download</button>
 <details><summary>Individual export files</summary><p>Use these if the combined download is too large.</p>
 <label>Export file<select value={chunkIndex} disabled={busy} onChange={event=>setChunkIndex(Number(event.target.value))}>{manifest.files.slice(Math.floor(chunkIndex/50)*50,Math.floor(chunkIndex/50)*50+50).map(file=><option key={file.sequence} value={file.sequence}>{file.category} · Part {file.sequence+1} · {file.itemCount} records</option>)}</select></label>
 <button disabled={busy||chunkIndex<50} onClick={()=>setChunkIndex(Math.max(0,Math.floor(chunkIndex/50)*50-50))}>Previous files</button><button disabled={busy||Math.floor(chunkIndex/50)*50+50>=manifest.files.length} onClick={()=>setChunkIndex(Math.floor(chunkIndex/50)*50+50)}>Next files</button>
 <button disabled={busy||!manifest.files.length} onClick={()=>void download(false)}>Prepare selected file</button>
 <button className="secondary-button" disabled={busy} onClick={()=>requestBrowserSave(new Blob([JSON.stringify(manifest,null,2)],{type:'application/json'}),'acloud-export-file-list.json')}>Download file list</button></details></div>}
 {prepared&&<p><a className="primary-button" href={prepared.url} download={prepared.filename}>Save file — {prepared.filename}</a><span> Check your browser’s Downloads after saving.</span></p>}
 <p role="status">{progress||message}</p><p><a href="/photos">Download photos</a> · <a href="/videos">Download videos</a> · <a href="mailto:Privacy247.acloud@useacloud.com">Privacy support</a></p>
 </section>;
}
