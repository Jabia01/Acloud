// Use only known resource types and server-owned identifiers. Never trust a
// client filename or invent a JPEG extension for an unknown original format.
export function originalDownloadName(id:string,mediaType:string,uti?:string){
 if(!/^[a-f0-9-]{36}$/i.test(id))throw Error('Invalid file identity');
 const extensions:Record<string,string>={'public.jpeg':'jpg','public.png':'png','public.heic':'heic','public.heif':'heif','public.mpeg-4':'mp4','com.apple.quicktime-movie':'mov'};
 const prefix=mediaType==='image'?'photo':mediaType==='video'?'video':'file';
 return `${prefix}-${id}.${uti&&extensions[uti]||'bin'}`;
}
