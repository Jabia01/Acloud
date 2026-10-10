import 'reflect-metadata';
import {NestFactory} from '@nestjs/core';
import {randomUUID} from 'node:crypto';
try{process.loadEnvFile('.env');}catch(e){if(e.code!=='ENOENT')throw e;}
const {validateConfiguration}=await import('../apps/api/dist/hardening/config.js');const configuration=validateConfiguration();const {lifecyclePolicy}=await import('../apps/api/dist/lifecycle/policy.js');lifecyclePolicy();
const {AppModule}=await import('../apps/api/dist/app.module.js'),{OperationsWorker}=await import('../apps/api/dist/hardening/operations.js');
if(!process.argv.includes('--apply')){console.info('Dry run: use --apply for bounded durable work. No schedules enabled automatically.');process.exit(0);}
const max=Number(process.argv.includes('--max')?process.argv[process.argv.indexOf('--max')+1]:20);if(!Number.isInteger(max)||max<1||max>100)throw new Error('Invalid worker bound');
let app,db,heartbeat;const workerId=randomUUID();let stopping=false;
process.once('SIGTERM',()=>{stopping=true;});process.once('SIGINT',()=>{stopping=true;});
try{
 app=await NestFactory.createApplicationContext(AppModule,{logger:false,abortOnError:false});
 const {BetaPolicy}=await import('../apps/api/dist/beta/policy.js');await app.get(BetaPolicy).startup();if(configuration.production||process.env.LIFECYCLE_LEDGER_DIR){const {LifecycleService}=await import('../apps/api/dist/lifecycle/service.js');await app.get(LifecycleService).replayTombstones();}
 const {DatabaseService}=await import('../apps/api/dist/database.service.js');db=app.get(DatabaseService);
 const beat=()=>db.query("INSERT INTO beta_worker_heartbeat(worker_id,state,last_seen_at) VALUES($1,'RUNNING',now()) ON CONFLICT(worker_id) DO UPDATE SET state='RUNNING',last_seen_at=now()",[workerId]);await beat();
 // This timer reports liveness only. Scheduling and job ownership remain in PostgreSQL.
 heartbeat=setInterval(()=>{void beat().catch(()=>{stopping=true;});},30000);heartbeat.unref();
 console.info(JSON.stringify(await app.get(OperationsWorker).run(max,()=>stopping)));
}catch{console.error('Durable worker unavailable; job state retained and sensitive details withheld.');process.exitCode=1;}
finally{if(heartbeat)clearInterval(heartbeat);await db?.query("UPDATE beta_worker_heartbeat SET state='STOPPED',last_seen_at=now() WHERE worker_id=$1",[workerId]).catch(()=>{});await app?.close();}
