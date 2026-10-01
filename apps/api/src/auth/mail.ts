import { Injectable } from '@nestjs/common';
import * as nodemailer from 'nodemailer';

export interface AccountMail { to: string; kind: 'verify' | 'reset'; token: string }
export abstract class AccountMailer { abstract send(message: AccountMail): Promise<void>; }

@Injectable()
export class LocalAccountMailer extends AccountMailer {
  async send(message: AccountMail): Promise<void> {
    // No production provider exists yet. Never silently send via a dev sink in production.
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
