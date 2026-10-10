import { Injectable } from '@nestjs/common';
import * as nodemailer from 'nodemailer';

export interface AccountMail { to: string; kind: 'verify' | 'reset' | 'security' | 'billing' | 'deletion' | 'invite'; token: string; lifecycleEvent?: 'REQUESTED' | 'CANCELLED' | 'PARTIAL' | 'COMPLETED' }
export abstract class AccountMailer { abstract send(message: AccountMail): Promise<void>; }

@Injectable()
export class LocalAccountMailer extends AccountMailer {
  async send(message: AccountMail): Promise<void> {
    // No production provider exists yet. Never silently send via a dev sink in production.
    if(process.env.EMAIL_PROVIDER==='smtp')return new SMTPAccountMailer().send(message);
    if (process.env.NODE_ENV === 'production' || process.env.DEV_MAIL_ENABLED !== 'true') throw new Error('Mail transport unavailable');
    const host = process.env.DEV_SMTP_HOST || '127.0.0.1';
    if (!['127.0.0.1', 'localhost', 'mail'].includes(host)) throw new Error('Local mail sink required');
    const base = process.env.WEB_BASE_URL || 'http://localhost:3000';
    const url = new URL(message.kind === 'verify' ? '/verify-email' : '/reset-password', base);
    // Fragments are never sent in HTTP requests or referrers, avoiding access-log leaks.
    url.hash = new URLSearchParams({ token: message.token }).toString();
    const transport = nodemailer.createTransport({ host, port: 1025, secure: false, connectionTimeout: 2000, socketTimeout: 3000, logger: false, debug: false });
    try {
      await transport.sendMail({ from: 'Account Service <accounts@example.invalid>', to: message.to, subject: message.kind === 'verify' ? 'Verify your email' : 'Reset your password', text: `Open this single-use link:\n${url.href}\nIf you did not request this, ignore this message.` });
    } finally { transport.close(); }
  }
}

// Test transport only; never registered by the application or exposed by an API.
export class MemoryAccountMailer extends AccountMailer {
  readonly messages: AccountMail[] = [];
  async send(message: AccountMail) { this.messages.push(message); }
}

export function betaEmailLink(message:AccountMail,originValue:string){const origin=new URL(originValue);if(origin.protocol!=='https:'||origin.username||origin.password||origin.pathname!=='/'||origin.search||origin.hash)throw new Error('Unsafe email origin');const u=new URL(message.kind==='invite'?'/beta/invite':message.kind==='verify'?'/verify-email':'/reset-password',origin);u.hash=new URLSearchParams({token:message.token}).toString();return u.href;}

@Injectable() export class SMTPAccountMailer extends AccountMailer{
 async send(message:AccountMail){
  if(process.env.EMAIL_PROVIDER!=='smtp'||process.env.SMTP_TLS!=='true'||!process.env.SMTP_HOST||!process.env.SMTP_USER||!process.env.SMTP_PASSWORD||!process.env.SMTP_FROM)throw new Error('Email unavailable');
  const port=Number(process.env.SMTP_PORT??465);if(![465,587].includes(port)||/[\r\n]/.test(process.env.SMTP_FROM))throw new Error('Unsafe email configuration');
  const origin=new URL(process.env.WEB_ORIGIN??'');if(origin.protocol!=='https:'||origin.username||origin.password)throw new Error('Unsafe email origin');
  let text='An account '+message.kind+' event occurred. Sign in through your trusted account website to review it.';
  if(message.kind==='deletion'){const messages={REQUESTED:'Account deletion was requested. Your sessions were revoked and renewal is being stopped. Cloud data is retained during the cancellation window. Use the cancellation details you saved on your trusted account website. Your device Photos are unchanged.',CANCELLED:'Account deletion was cancelled. Sign in again. Subscription renewal remains cancelled. Your device Photos are unchanged.',PARTIAL:'Account deletion requires further processing. Access remains restricted. Completed steps are recorded and remaining steps are being retried or reviewed. Your device Photos are unchanged.',COMPLETED:'Your account deletion completed. Cloud objects covered by the verified deletion inventory were removed. Necessary billing, security and deletion evidence may be retained according to the reviewed policy. Your device Photos are unchanged.'};if(!message.lifecycleEvent)throw new Error('Lifecycle notification unavailable');text=messages[message.lifecycleEvent];}
  if(['verify','reset','invite'].includes(message.kind)){text='Open this single-use link: '+betaEmailLink(message,origin.href)+'\nIf you did not request this, ignore this message.';}
  const transport=nodemailer.createTransport({host:process.env.SMTP_HOST,port,secure:port===465,requireTLS:true,tls:{rejectUnauthorized:true},auth:{user:process.env.SMTP_USER,pass:process.env.SMTP_PASSWORD},logger:false,debug:false,connectionTimeout:5000,socketTimeout:10000});
  try{await transport.sendMail({from:{name:'Account Service',address:process.env.SMTP_FROM},to:message.to,subject:'Account '+message.kind,text});}finally{transport.close();}
 }
}
