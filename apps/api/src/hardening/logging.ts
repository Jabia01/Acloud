import {randomUUID} from 'node:crypto';
// Allowlisting discards unknown fields entirely, including nested metadata and exception objects.
export function safeLog(event:{code:string;severity?:string;service?:string;correlationId?:string;count?:number;durationMs?:number}){
 const code=/^[A-Z][A-Z0-9_]{0,63}$/.test(event.code)?event.code:'UNKNOWN_EVENT';
 return{timestamp:new Date().toISOString(),code,severity:['INFO','WARNING','ERROR'].includes(event.severity??'')?event.severity:'INFO',service:['api','worker','audit','email'].includes(event.service??'')?event.service:'api',correlationId:/^[a-f0-9-]{36}$/.test(event.correlationId??'')?event.correlationId:randomUUID(),...(Number.isSafeInteger(event.count)&&event.count!>=0?{count:event.count}:{}),...(Number.isSafeInteger(event.durationMs)&&event.durationMs!>=0?{durationMs:event.durationMs}:{})};
}
export function logEvent(event:Parameters<typeof safeLog>[0]){console.info(JSON.stringify(safeLog(event)));}
