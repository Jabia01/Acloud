import {ownerPaymentTestConfiguration} from '../../../../infrastructure/railway/owner-payment-test.cjs';
export function paymentConfiguration(e:NodeJS.ProcessEnv=process.env){
 const environment=e.NODE_ENV==='production'&&e.APP_ENV!=='staging'?'LIVE':'TEST';
 const key=e.PAYSTACK_SECRET_KEY||'';
 const privateTest=ownerPaymentTestConfiguration(e);
 const ready=e.BILLING_ENABLED==='true'&&(environment==='LIVE'?/^sk_live_[A-Za-z0-9]+$/:/^sk_test_[A-Za-z0-9]+$/).test(key)
  &&(!e.PAYSTACK_ENVIRONMENT||e.PAYSTACK_ENVIRONMENT===environment)
  &&(privateTest?.active===true||e.OWNER_DEVICE_TEST_ENABLED!=='true'&&!(e.NODE_ENV==='production'&&e.APP_ENV==='staging'&&(e.BETA_ENABLED!=='true'||e.BETA_ALLOW_PAYMENTS!=='true')));
 return{provider:'PAYSTACK' as const,environment,checkoutEnabled:ready,message:ready?(privateTest?'Private Paystack test mode for the approved account. No live payments.':environment==='TEST'?'Paystack test mode. No live payments.':'Payments are processed securely by Paystack.'):'Payments are being prepared. Checkout is currently unavailable.'};
}
