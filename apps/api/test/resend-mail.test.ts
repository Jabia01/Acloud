import test from 'node:test';
import assert from 'node:assert/strict';
import {randomBytes} from 'node:crypto';
import {ResendAccountMailer,LocalAccountMailer} from '../src/auth/mail';
test('Resend uses fixed HTTPS endpoint, fragment links, and suppresses provider errors',async()=>{
 const previous={...process.env},transport=globalThis.fetch;
 try{
 Object.assign(process.env,{EMAIL_PROVIDER:'resend',RESEND_API_KEY:'re_'+randomBytes(24).toString('hex'),SMTP_FROM:'accounts@notify.unit.test',WEB_ORIGIN:'https://staging.unit.test'});
 const token=randomBytes(32).toString('base64url');let calls=0;
 globalThis.fetch=async(url,options)=>{calls++;assert.equal(url,'https://api.resend.com/emails');assert.equal(options?.redirect,'error');assert.ok(options?.signal);assert.equal(options?.method,'POST');const body=JSON.parse(String(options?.body));assert.deepEqual(body.to,['owner@unit.test']);assert.ok(body.text.includes('/verify-email#token='+token));assert.equal(body.from,'Account Service <accounts@notify.unit.test>');return new Response(JSON.stringify({id:'generated-id'}),{status:200});};
 await new LocalAccountMailer().send({to:'owner@unit.test',kind:'verify',token});assert.equal(calls,1);
 globalThis.fetch=async()=>new Response(JSON.stringify({message:token}),{status:403});
 await assert.rejects(new ResendAccountMailer().send({to:'owner@unit.test',kind:'verify',token}),{message:'Email delivery unavailable'});
 globalThis.fetch=async()=>new Response('{}',{status:200});
 await assert.rejects(new ResendAccountMailer().send({to:'owner@unit.test',kind:'verify',token}),{message:'Email delivery unavailable'});
 process.env.WEB_ORIGIN='http://unsafe.unit.test';calls=0;globalThis.fetch=async()=>{calls++;throw Error('unexpected');};
 await assert.rejects(new ResendAccountMailer().send({to:'owner@unit.test',kind:'verify',token}));assert.equal(calls,0);
 }finally{globalThis.fetch=transport;for(const key of Object.keys(process.env))if(!(key in previous))delete process.env[key];Object.assign(process.env,previous);}
});
