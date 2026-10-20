// Explicit private TEST checkout; independent of broad beta/live-payment acceptance.
function ownerPaymentTestConfiguration(e=process.env,now=Date.now()){
 const flag=e.OWNER_PAYMENT_TEST_ENABLED;
 if(flag===undefined||flag==='false')return null;
 const refuse=code=>{const error=new Error('Invalid private payment test configuration');error.code=code;throw error};
 for(const [name,expected] of Object.entries({OWNER_PAYMENT_TEST_ENABLED:'true',NODE_ENV:'production',APP_ENV:'staging',STORAGE_ENVIRONMENT:'staging',STORAGE_PROVIDER:'backblaze_b2',OWNER_DEVICE_TEST_ENABLED:'true',BILLING_ENABLED:'true',PAYSTACK_ENVIRONMENT:'TEST'}))if(e[name]!==expected)refuse('PAYMENT_TEST_'+name);
 if(!/^sk_test_[A-Za-z0-9]{12,}$/.test(e.PAYSTACK_SECRET_KEY??''))refuse('PAYMENT_TEST_SECRET_KEY');
 const closed=['BETA_ENABLED','BETA_ALLOW_REAL_MEDIA','BETA_ALLOW_PAYMENTS','BETA_ALLOW_B2','BETA_ALLOW_FREE_UP_SPACE','BETA_ALLOW_SUPPORT_TOOLS','CUSTOMER_REGISTRATION_ENABLED','ENABLE_FREE_UP_SPACE','ACCOUNT_DELETION_ENABLED','ACCOUNT_DELETION_EXECUTION_ENABLED','RETENTION_EXECUTION_ENABLED','RESTORE_ENABLED'];
 for(const name of closed)if(e[name]!=='false')refuse('PAYMENT_TEST_'+name);
 if(e.NODE_TLS_REJECT_UNAUTHORIZED==='0')refuse('PAYMENT_TEST_TLS');
 const account=e.OWNER_PAYMENT_TEST_ACCOUNT_ID,hash=e.OWNER_PAYMENT_TEST_RESOURCE_HASH;
 if(!/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i.test(account??'')||account!==e.OWNER_DEVICE_TEST_ACCOUNT_ID)refuse('PAYMENT_TEST_ACCOUNT_BINDING');
 if(!/^[a-f0-9]{64}$/.test(hash??'')||hash!==e.OWNER_DEVICE_TEST_RESOURCE_HASH)refuse('PAYMENT_TEST_RESOURCE_BINDING');
 const start=Date.parse(e.OWNER_PAYMENT_TEST_STARTS_AT??''),end=Date.parse(e.OWNER_PAYMENT_TEST_EXPIRES_AT??''),ownerStart=Date.parse(e.OWNER_DEVICE_TEST_STARTS_AT??''),ownerEnd=Date.parse(e.OWNER_DEVICE_TEST_EXPIRES_AT??'');
 if(![start,end,ownerStart,ownerEnd].every(Number.isFinite)||end<=start||end-start>24*3600000||start<ownerStart||end>ownerEnd)refuse('PAYMENT_TEST_WINDOW');
 // Expiry closes checkout/work without crashing the existing media service on restart.
 return{account,start,end,active:now>=start&&now<end};
}

exports.ownerPaymentTestConfiguration=ownerPaymentTestConfiguration;
