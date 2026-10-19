import {paymentConfiguration} from './configuration';
import {Injectable,ServiceUnavailableException} from '@nestjs/common';
import {createHmac,timingSafeEqual} from 'node:crypto';
export type Price={amount_minor:string;currency:string;provider_plan_code:string;billing_interval:string;environment:string};
export type VerifiedPayment={id:string;reference:string;status:string;amount:number;currency:string;customerCode:string;paidAt:string;authorization?:string;domain:string};
export type ProviderSubscription={code:string;customerCode:string;planCode:string;status:string;nextPaymentDate:string|null;invoiceReferences?:string[]};
export abstract class BillingProvider {
 abstract createCustomer(userId:string,email:string):Promise<string>;
 abstract initializeCheckout(email:string,reference:string,price:Price):Promise<string>;
 abstract verifyTransaction(reference:string):Promise<VerifiedPayment>;
 abstract createSubscription(customer:string,price:Price,start:Date,authorization?:string):Promise<ProviderSubscription>;
 abstract cancelSubscription(code:string):Promise<void>;
 abstract fetchSubscription(code:string):Promise<ProviderSubscription>;
 abstract validateWebhookSignature(raw:Buffer,signature:string):boolean;
 abstract validatePrice(price:Price):Promise<void>;
}
export function safeCheckoutUrl(value:string){try{const u=new URL(value);return u.protocol==='https:'&&u.hostname==='checkout.paystack.com'&&!u.username&&!u.password&&!u.port?u.href:null;}catch{return null;}}
@Injectable()
export class PaystackBillingProvider extends BillingProvider {
 private key(){if(!paymentConfiguration().checkoutEnabled)throw new ServiceUnavailableException('Billing unavailable');return process.env.PAYSTACK_SECRET_KEY!;}
 private async request(path:string,body?:unknown){try{const r=await fetch(`https://api.paystack.co${path}`,{method:body?'POST':'GET',headers:{Authorization:`Bearer ${this.key()}`,'Content-Type':'application/json'},...(body?{body:JSON.stringify(body)}:{}),redirect:'error',signal:AbortSignal.timeout(8000)});const value=await r.json() as any;if(!r.ok||value.status!==true )throw new Error();return value.data??{};}catch{throw new ServiceUnavailableException('Billing provider unavailable');}}
 async createCustomer(userId:string,email:string){
  // Existing email is only a lookup hint. Ownership metadata must match before reuse.
  let existing:any=null;try{existing=await this.request(`/customer/${encodeURIComponent(email)}`);}catch{/* A create failure remains a safe retry, never ownership by email alone. */}
  const c=existing??await this.request('/customer',{email,metadata:{account_id:userId}});
  if(c.metadata?.account_id!==userId||typeof c.customer_code!=='string')throw new ServiceUnavailableException('Billing identity unavailable');return c.customer_code;
 }
 async validatePrice(p:Price){const d=await this.request(`/plan/${encodeURIComponent(p.provider_plan_code)}`);if(d.plan_code!==p.provider_plan_code||d.is_deleted===true||d.is_archived===true||Number(d.amount)!==Number(p.amount_minor)||d.currency!==p.currency||d.interval!==(p.billing_interval==='MONTHLY'?'monthly':'annually')||d.domain?.toUpperCase()!==p.environment)throw new ServiceUnavailableException('Pricing unavailable');}
 async initializeCheckout(email:string,reference:string,p:Price){const origin=process.env.WEB_ORIGIN;if(!origin)throw new ServiceUnavailableException('Billing unavailable');const u=new URL(origin);if(u.username||u.password||(process.env.NODE_ENV==='production'&&u.protocol!=='https:'))throw new ServiceUnavailableException('Billing unavailable');
  // First period is a one-off exact-price payment. Recurrence starts only after verification.
  const d=await this.request('/transaction/initialize',{email,amount:String(p.amount_minor),currency:p.currency,reference,callback_url:new URL('/billing/success',u).href,channels:['card']});if(d.reference!==reference||!safeCheckoutUrl(d.authorization_url))throw new ServiceUnavailableException('Checkout unavailable');return d.authorization_url;
 }
 async verifyTransaction(reference:string){const d=await this.request(`/transaction/verify/${encodeURIComponent(reference)}`);return{id:String(d.id),reference:d.reference,status:d.status,amount:d.amount,currency:d.currency,customerCode:d.customer?.customer_code,paidAt:d.paid_at,authorization:d.authorization?.reusable?d.authorization.authorization_code:undefined,domain:d.domain};}
 private subscription(d:any):ProviderSubscription{return{code:d.subscription_code,customerCode:typeof d.customer==='object'?d.customer.customer_code:'',planCode:typeof d.plan==='object'?d.plan.plan_code:'',status:d.status,nextPaymentDate:d.next_payment_date??null,invoiceReferences:(d.invoices??[]).map((i:any)=>i.transaction?.reference).filter((r:unknown)=>typeof r==='string').slice(0,100)};}
 async fetchSubscription(code:string){return this.subscription(await this.request(`/subscription/${encodeURIComponent(code)}`));}
 async createSubscription(customer:string,p:Price,start:Date,authorization?:string){
  const c=await this.request(`/customer/${encodeURIComponent(customer)}`);const candidates=(c.subscriptions??[]).filter((s:any)=>s.plan?.plan_code===p.provider_plan_code&&['active','non-renewing'].includes(s.status));
  // Never repeat an ambiguous provider create. A canonical match must be unique and scheduled correctly.
  if(candidates.length){if(candidates.length!==1)throw new ServiceUnavailableException('Subscription reconciliation required');const s=await this.fetchSubscription(candidates[0].subscription_code);if(!s.nextPaymentDate||Math.abs(Date.parse(s.nextPaymentDate)-start.getTime())>60000)throw new ServiceUnavailableException('Subscription reconciliation required');return s;}
  if(!authorization)throw new ServiceUnavailableException('Reusable payment authorization required');
  const s=await this.request('/subscription',{customer,plan:p.provider_plan_code,authorization,start_date:start.toISOString()});return this.fetchSubscription(s.subscription_code);
 }
 async cancelSubscription(code:string){const d=await this.request(`/subscription/${encodeURIComponent(code)}`);if(['non-renewing','complete','cancelled'].includes(d.status))return;if(typeof d.email_token!=='string')throw new ServiceUnavailableException('Cancellation unavailable');await this.request('/subscription/disable',{code,token:d.email_token});}
 validateWebhookSignature(raw:Buffer,signature:string){try{if(!/^[a-f0-9]{128}$/i.test(signature))return false;return timingSafeEqual(createHmac('sha512',this.key()).update(raw).digest(),Buffer.from(signature,'hex'));}catch{return false;}}
}
