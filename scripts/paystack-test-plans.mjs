import {readFile,writeFile,lstat,mkdir,rename} from 'node:fs/promises';
import {pathToFileURL} from 'node:url';
import {dirname} from 'node:path';
export const approvedTestPlans=[['STANDARD_32','32 GB',599],['STANDARD_64','64 GB',999],['STANDARD_128','128 GB',1999],['STANDARD_256','256 GB',3499],['STANDARD_512','512 GB',6499],['STANDARD_1TB','1 TB',10999],['STANDARD_2TB','2 TB',21999]].flatMap(([code,label,monthly])=>['MONTHLY','ANNUAL'].map(interval=>({code,label,interval,currency:'NGN',amountMinor:monthly*100*(interval==='ANNUAL'?10:1),providerInterval:interval==='MONTHLY'?'monthly':'annually',name:`Acloud TEST ${label} ${interval} 2026-10`})));
function valid(plan,expected){return plan&&/^PLN_[A-Za-z0-9]+$/.test(plan.plan_code)&&plan.domain==='test'&&plan.currency===expected.currency&&Number(plan.amount)===expected.amountMinor&&plan.interval===expected.providerInterval&&plan.is_deleted!==true&&plan.is_archived!==true;}
export async function provisionTestPlans({key,apply=false,fetcher=fetch,onProgress=async()=>{}}){
 if(typeof key!=='string'||!/^sk_test_[A-Za-z0-9]{12,}$/.test(key))throw Error('TEST_KEY_REQUIRED');
 async function request(path,body){
  let response;try{response=await fetcher('https://api.paystack.co'+path,{method:body?'POST':'GET',redirect:'error',signal:AbortSignal.timeout(15000),headers:{Authorization:'Bearer '+key,'Content-Type':'application/json'},...(body?{body:JSON.stringify(body)}:{})});}catch{throw Error(body?'CREATE_OUTCOME_UNKNOWN_CHECK_DASHBOARD':'PROVIDER_UNAVAILABLE');}
  if(!response.ok)throw Error(body?'CREATE_REJECTED_CHECK_DASHBOARD':'PROVIDER_REJECTED');
  const text=await response.text();if(text.length>2*1024*1024)throw Error('PROVIDER_RESPONSE_BOUND');
  let result;try{result=JSON.parse(text)}catch{throw Error('PROVIDER_RESPONSE_INVALID')}
  if(result.status!==true)throw Error('PROVIDER_REJECTED');return result;
 }
 const existing=[];
 for(let page=1;page<=20;page++){
  const r=await request(`/plan?perPage=100&page=${page}`);if(!Array.isArray(r.data))throw Error('PLAN_LIST_INVALID');existing.push(...r.data);
  if(r.data.length<100)break;if(page===20)throw Error('PLAN_LIST_BOUND');
 }
 // Preflight all conflicts before making any external change. Never edit someone else's plans.
 for(const p of approvedTestPlans){const matches=existing.filter(r=>r.name===p.name);if(matches.length>1||matches.length===1&&!valid(matches[0],p))throw Error('EXISTING_TEST_PLAN_CONFLICT');}
 const mapping=[];
 for(const p of approvedTestPlans){
  let remote=existing.find(r=>r.name===p.name);
  if(!remote&&!apply){mapping.push({...p,state:'MISSING'});continue}
  if(!remote)remote=(await request('/plan',{name:p.name,amount:p.amountMinor,interval:p.providerInterval,currency:p.currency,description:'Acloud staging test plan; no live payments.',send_invoices:false,send_sms:false})).data;
  if(!valid(remote,p))throw Error('CANONICAL_TEST_PLAN_MISMATCH');
  const canonical=(await request('/plan/'+remote.plan_code)).data;
  if(!valid(canonical,p)||canonical.plan_code!==remote.plan_code)throw Error('CANONICAL_TEST_PLAN_MISMATCH');
  mapping.push({...p,providerPlanCode:canonical.plan_code,state:'VERIFIED'});
  await onProgress({environment:'TEST',currency:'NGN',plans:mapping});
 }
 return{environment:'TEST',currency:'NGN',plans:mapping};
}
if(process.argv[1]&&import.meta.url===pathToFileURL(process.argv[1]).href){
 try{
  const args=process.argv.slice(2),apply=args.includes('--apply'),keyIndex=args.indexOf('--key-file'),outputIndex=args.indexOf('--output');
  if(keyIndex<0||outputIndex<0||!args[keyIndex+1]||!args[outputIndex+1])throw Error('KEY_FILE_AND_OUTPUT_REQUIRED');
  const file=args[keyIndex+1],output=args[outputIndex+1],stat=await lstat(file);
  if(!stat.isFile()||stat.isSymbolicLink()||(stat.mode&0o077))throw Error('PRIVATE_KEY_FILE_REQUIRED');
  const key=(await readFile(file,'utf8')).trim();
  const save=async result=>{await mkdir(dirname(output),{recursive:true,mode:0o700});await writeFile(output+'.tmp',JSON.stringify(result,null,2),{mode:0o600});await rename(output+'.tmp',output)};
  const result=await provisionTestPlans({key,apply,onProgress:apply?save:undefined});await save(result);
  console.log(JSON.stringify({environment:'TEST',apply,verified:result.plans.filter(p=>p.state==='VERIFIED').length,missing:result.plans.filter(p=>p.state==='MISSING').length,credentialsPrinted:false,chargesCreated:false}));
 }catch(error){const allowed=['TEST_KEY_REQUIRED','KEY_FILE_AND_OUTPUT_REQUIRED','PRIVATE_KEY_FILE_REQUIRED','PROVIDER_UNAVAILABLE','PROVIDER_REJECTED','PLAN_LIST_INVALID','PLAN_LIST_BOUND','EXISTING_TEST_PLAN_CONFLICT','CREATE_OUTCOME_UNKNOWN_CHECK_DASHBOARD','CREATE_REJECTED_CHECK_DASHBOARD','PROVIDER_RESPONSE_BOUND','PROVIDER_RESPONSE_INVALID','CANONICAL_TEST_PLAN_MISMATCH'];console.error(JSON.stringify({result:'STOPPED',reason:allowed.includes(error.message)?error.message:'LOCAL_OR_PROVIDER_UNAVAILABLE',credentialsPrinted:false}));process.exitCode=1;}
}
