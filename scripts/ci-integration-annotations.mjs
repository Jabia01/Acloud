import {readFile} from 'node:fs/promises';
// Emit public source locations only. Never publish test output, error bodies or environment values.
export function failureLocations(log){
 const tail=log.includes('failing tests:')?log.slice(log.lastIndexOf('failing tests:')):log;
 const locations=new Map();
 for(const match of tail.matchAll(/(?:test at |\/apps\/api\/)(?:test\/)([A-Za-z0-9_.-]+\.ts):([1-9][0-9]*):([1-9][0-9]*)/g)){
  const path='apps/api/test/'+match[1],line=Number(match[2]),column=Number(match[3]);
  if(!Number.isSafeInteger(line)||!Number.isSafeInteger(column))continue;
  locations.set(path+':'+line+':'+column,{path,line,column});if(locations.size===20)break;
 }
 return [...locations.values()];
}
if(process.argv[1]&&import.meta.url===new URL('file://'+process.argv[1]).href){
 const locations=failureLocations(await readFile(process.argv[2],'utf8'));
 for(const {path,line,column}of locations)console.info(`::error file=${path},line=${line},col=${column}::Integration test failure at this source location; details are in the authenticated job log.`);
}
