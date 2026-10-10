import {Inject,Injectable} from '@nestjs/common';import {randomUUID} from 'node:crypto';import {DatabaseService} from '../database.service';
export type SafeFailure={id:string;code:'API_FAILURE'|'WORKER_FAILURE'|'CLIENT_CRASH';service:'api'|'worker'|'ios'|'web';correlationId:string};
export function failureProjection(value:unknown):SafeFailure{const v=value&&typeof value==='object'?value as Record<string,unknown>:{};return{id:randomUUID(),code:['API_FAILURE','WORKER_FAILURE','CLIENT_CRASH'].includes(String(v.code))?v.code as SafeFailure['code']:'API_FAILURE',service:['api','worker','ios','web'].includes(String(v.service))?v.service as SafeFailure['service']:'api',correlationId:randomUUID()};}
export abstract class ErrorSink{abstract deliver(event:SafeFailure):Promise<void>;}
export class PendingErrorSink extends ErrorSink{async deliver(){throw new Error('Error vendor pending');}}
export class MemoryErrorSink extends ErrorSink{events=new Map<string,SafeFailure>();async deliver(event:SafeFailure){this.events.set(event.id,event);}}
@Injectable()export class BetaErrorReporter{
 constructor(@Inject(DatabaseService)private db:DatabaseService,@Inject(ErrorSink)private sink:ErrorSink){}
 async capture(value:unknown){const e=failureProjection(value);await this.db.query('INSERT INTO beta_error_outbox(id,code,service,correlation_id) VALUES($1,$2,$3,$4)',[e.id,e.code,e.service,e.correlationId]);return{id:e.id};}
 async flush(){const rows=(await this.db.query('SELECT * FROM beta_error_outbox WHERE delivered_at IS NULL ORDER BY created_at,id LIMIT 100')).rows;let delivered=0;for(const r of rows){await this.db.query('UPDATE beta_error_outbox SET attempts=attempts+1 WHERE id=$1',[r.id]);try{await this.sink.deliver({id:r.id,code:r.code,service:r.service,correlationId:r.correlation_id});await this.db.query('UPDATE beta_error_outbox SET delivered_at=now() WHERE id=$1',[r.id]);delivered++;}catch{}}return{delivered,pending:rows.length-delivered};}
}
