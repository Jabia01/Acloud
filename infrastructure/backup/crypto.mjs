import {createCipheriv,createDecipheriv,randomBytes} from 'node:crypto';
import {createReadStream,createWriteStream} from 'node:fs';
import {open,rename,unlink,stat} from 'node:fs/promises';
import {pipeline} from 'node:stream/promises';
const magic=Buffer.from('ACLOUDDB1');const headerLength=magic.length+12;
export async function encrypt(input,output,key){
 if(key.length!==32)throw Error('KEY_LENGTH');
 const header=Buffer.concat([magic,randomBytes(12)]),cipher=createCipheriv('aes-256-gcm',key,header.subarray(magic.length));cipher.setAAD(header);
 const handle=await open(output,'wx',0o600);await handle.write(header);await handle.close();
 try{await pipeline(input,cipher,createWriteStream(output,{flags:'a',mode:0o600}));const file=await open(output,'a');try{await file.write(cipher.getAuthTag());}finally{await file.close();}}
 catch(error){await unlink(output).catch(()=>{});throw error;}
}
export async function decrypt(input,output,key){
 if(key.length!==32)throw Error('KEY_LENGTH');
 const size=(await stat(input)).size;if(size<headerLength+16)throw Error('INVALID_BACKUP');
 const handle=await open(input,'r');const header=Buffer.alloc(headerLength),tag=Buffer.alloc(16);
 try{await handle.read(header,0,headerLength,0);await handle.read(tag,0,16,size-16);}finally{await handle.close();}
 if(!header.subarray(0,magic.length).equals(magic))throw Error('INVALID_BACKUP');
 const decipher=createDecipheriv('aes-256-gcm',key,header.subarray(magic.length));decipher.setAAD(header);decipher.setAuthTag(tag);
 // Callers may only restore the returned path after full authentication succeeds.
 const partial=output+'.partial-'+randomBytes(8).toString('hex');
 try{await pipeline(createReadStream(input,{start:headerLength,end:size-17}),decipher,createWriteStream(partial,{flags:'wx',mode:0o600}));
 const final=await open(output,'wx',0o600);await final.close();await rename(partial,output);return output;
 }catch(error){await unlink(partial).catch(()=>{});throw error;}
}
