// Browsers do not confirm a file was saved. Keep the object URL alive long
// enough for Safari to consume it, and never label a requested save as complete.
export function requestBrowserSave(blob:Blob,filename:string){
 const url=URL.createObjectURL(blob),link=document.createElement('a');
 link.href=url;link.download=filename;document.body.appendChild(link);
 try{link.click();}finally{link.remove();setTimeout(()=>URL.revokeObjectURL(url),60000);}
}
