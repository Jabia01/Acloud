import {setTimeout as sleep} from 'node:timers/promises';
const statuses=new Set([408,429,500,502,503,504]);
const networkCodes=new Set(['ECONNRESET','ETIMEDOUT','EAI_AGAIN','UND_ERR_CONNECT_TIMEOUT','UND_ERR_HEADERS_TIMEOUT','UND_ERR_BODY_TIMEOUT','UND_ERR_SOCKET']);
export function transient(error){if(!error)return false;return statuses.has(error.status)||error.name==='TimeoutError'||networkCodes.has(error.cause?.code);}
export function delay(attempt,retryAfter,{now=Date.now(),random=Math.random}={}){
 const exponential=Math.min(30000,1000*2**attempt),jitter=Math.floor(exponential*.25*random());
 let provider=0;
 if(typeof retryAfter==='string'&&retryAfter.trim()){
  const seconds=Number(retryAfter);provider=Number.isFinite(seconds)&&seconds>=0?seconds*1000:Date.parse(retryAfter)-now;
 }
 if(Number.isFinite(provider)&&provider>60000)return null;
 return Math.min(60000,Math.max(exponential+jitter,Number.isFinite(provider)?provider:0));
}
export async function retry(operation,{wait=sleep,random=Math.random,now=Date.now}={}){
 for(let attempt=0;attempt<5;attempt++){
  try{return await operation();}catch(error){if(attempt===4||!transient(error))throw error;const milliseconds=delay(attempt,error.retryAfter,{now:now(),random});if(milliseconds===null)throw error;await wait(milliseconds);}
 }
}
