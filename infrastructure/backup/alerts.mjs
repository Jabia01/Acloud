import {createHash} from 'node:crypto';
export async function sendBackupAlert(env,{mode,code,test=false,testId='manual'},transport=fetch){
 if(!/^re_[A-Za-z0-9_-]+$/.test(env.BACKUP_ALERT_RESEND_KEY??'')||!env.BACKUP_ALERT_FROM||/[\r\n]/.test(env.BACKUP_ALERT_FROM))throw Error('ALERT_CONFIGURATION_REQUIRED');
 if(!['Support247.acloud@useacloud.com','Privacy247.acloud@useacloud.com'].includes(env.BACKUP_ALERT_TO))throw Error('ALERT_RECIPIENT');
 if(!['daily','monitor','restore','alert-test'].includes(mode)||!/^[A-Z_0-9]{1,60}$/.test(code)||test&&(mode!=='alert-test'||code!=='ALERT_DELIVERY_TEST')||!test&&mode==='alert-test')throw Error('ALERT_SCOPE');
 const text=test?'This is an authorized Acloud staging backup alert delivery test. No backup failure or outage was detected. Please confirm that this message reached the configured privacy/support inbox.':'Staging database backup check failed. Mode: '+mode+'. Code: '+code+'. Check the protected backup job logs. Keep existing recovery copies; do not restore over the live database.';
 const key=createHash('sha256').update(mode+'|'+code+'|'+new Date().toISOString().slice(0,10)+(test?'|'+testId:'')).digest('hex');
 const response=await transport('https://api.resend.com/emails',{method:'POST',headers:{Authorization:'Bearer '+env.BACKUP_ALERT_RESEND_KEY,'Content-Type':'application/json','Idempotency-Key':key},body:JSON.stringify({from:env.BACKUP_ALERT_FROM,to:[env.BACKUP_ALERT_TO],subject:test?'Acloud backup alert delivery test':'Acloud staging backup needs attention',text}),redirect:'error',signal:AbortSignal.timeout(15000)});
 if(!response.ok){await response.body?.cancel();throw Error('ALERT_DELIVERY_FAILED');}
 let receipt;try{receipt=await response.json();}catch{throw Error('ALERT_DELIVERY_FAILED');}
 if(typeof receipt?.id!=='string'||!/^[A-Za-z0-9_-]{1,128}$/.test(receipt.id))throw Error('ALERT_DELIVERY_FAILED');
 return {accepted:true,messageId:receipt.id};
}
