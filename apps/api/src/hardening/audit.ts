import {auditProjection} from './projections';
import {Inject,Injectable} from '@nestjs/common';import {randomUUID} from 'node:crypto';import {DatabaseService} from '../database.service';
export type AuditRecord={id:string;actor_type:string;actor_id:string|null;role:string|null;action:string;target_type:string;target_id:string|null;correlation_id:string;outcome:string;summary:Record<string,unknown>;created_at:Date};
export abstract class AuditSink{abstract deliver(record:AuditRecord):Promise<void>;}
export class PendingAuditSink extends AuditSink{async deliver(){throw new Error('External audit sink pending');}}
export class MemoryAuditSink extends AuditSink{readonly records=new Map<string,AuditRecord>();async deliver(r:AuditRecord){this.records.set(r.id,r);}}
@Injectable() export class AuditOutbox{
 constructor(@Inject(DatabaseService)private db:DatabaseService,@Inject(AuditSink)private sink:AuditSink){}
 async forward(limit=100){const rows=(await this.db.query('SELECT a.* FROM audit_outbox o JOIN security_audit a ON a.id=o.id WHERE o.delivered_at IS NULL AND o.available_at<=now() ORDER BY o.available_at,o.id LIMIT $1',[Math.min(limit,100)])).rows;let delivered=0;for(const r of rows){try{await this.sink.deliver(auditProjection(r as AuditRecord));await this.db.query('UPDATE audit_outbox SET delivered_at=now(),attempts=attempts+1,last_error_code=NULL WHERE id=$1 AND delivered_at IS NULL',[r.id]);delivered++;}catch{await this.db.query("UPDATE audit_outbox SET attempts=attempts+1,available_at=now()+LEAST(3600,15*power(2,LEAST(attempts,8)))*interval '1 second',last_error_code='AUDIT_SINK_UNAVAILABLE' WHERE id=$1 AND delivered_at IS NULL",[r.id]);}}return{delivered,pending:rows.length-delivered};}
 async record(action:string,targetId:string|null,actorId:string|null,summary:Record<string,unknown>={}){const id=randomUUID();await this.db.query("INSERT INTO security_audit(id,actor_type,actor_id,action,target_type,target_id,correlation_id,outcome,summary) VALUES($1,'SYSTEM',$2,$3,'account',$4,$1,'RECORDED',$5)",[id,actorId,action,targetId,JSON.stringify(summary)]);return id;}
}
