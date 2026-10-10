// Supervisor restarts bounded children; PostgreSQL owns schedules and lease fencing.
import {spawn} from 'node:child_process';
export async function supervise({signal,spawnWorker=()=>spawn(process.execPath,['scripts/run-durable-worker.mjs','--apply','--max','1'],{env:process.env,stdio:'inherit'}),delay=15000}){
 while(!signal.aborted){
  await new Promise(resolve=>{const child=spawnWorker();const stop=()=>child.kill('SIGTERM');const finish=()=>{signal.removeEventListener('abort',stop);resolve();};signal.addEventListener('abort',stop,{once:true});child.once('error',finish);child.once('exit',finish);if(signal.aborted)stop();});
  if(!signal.aborted)await new Promise(resolve=>{const finish=()=>{clearTimeout(timer);signal.removeEventListener('abort',finish);resolve();};const timer=setTimeout(finish,delay);signal.addEventListener('abort',finish,{once:true});if(signal.aborted)finish();});
 }
}
if(process.argv[1]?.endsWith('supervise-worker.mjs')){const controller=new AbortController();const stop=()=>controller.abort();process.once('SIGTERM',stop);process.once('SIGINT',stop);await supervise({signal:controller.signal});}
