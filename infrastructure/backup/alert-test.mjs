import {sendBackupAlert} from './alerts.mjs';
const env={};for(const name of ['BACKUP_ALERT_RESEND_KEY','BACKUP_ALERT_TO','BACKUP_ALERT_FROM']){env[name]=process.env[name]?.trim();delete process.env[name];}
try{const receipt=await sendBackupAlert(env,{mode:'alert-test',code:'ALERT_DELIVERY_TEST',test:true,testId:process.env.GITHUB_RUN_ID??'manual'});console.log(JSON.stringify({result:'PASS',mode:'alert-test',...receipt,inboxReceiptConfirmed:false}));}
catch{console.error(JSON.stringify({result:'FAILED',mode:'alert-test',code:'ALERT_TEST_FAILED'}));process.exitCode=1;}
