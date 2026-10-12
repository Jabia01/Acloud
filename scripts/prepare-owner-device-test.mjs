// Generate only the six non-secret owner-test settings. Never changes a cloud service or DB.
// Run using node --env-file=<private API env file> scripts/prepare-owner-device-test.mjs ACCOUNT_UUID DEVICE_UUID OUTPUT_FILE
import {createRequire} from 'node:module';
import {writeFileSync} from 'node:fs';
const require=createRequire(import.meta.url);
const {ownerTestBinding,ownerTestConfiguration}=require('../apps/api/dist/beta/owner-test.js');
try {
 const [account,device,out]=process.argv.slice(2);
 if(!out||process.argv.length!==5)throw new Error();
 const now=Date.now();
 const patch={OWNER_DEVICE_TEST_ENABLED:'true',OWNER_DEVICE_TEST_ACCOUNT_ID:account,OWNER_DEVICE_TEST_DEVICE_ID:device,
 OWNER_DEVICE_TEST_STARTS_AT:new Date(now).toISOString(),OWNER_DEVICE_TEST_EXPIRES_AT:new Date(now+2*3600*1000).toISOString(),
 OWNER_DEVICE_TEST_RESOURCE_HASH:ownerTestBinding(process.env)};
 ownerTestConfiguration({...process.env,...patch});
 writeFileSync(out,Object.entries(patch).map(([k,v])=>k+'='+v).join('\n')+'\n',{mode:0o600,flag:'wx'});
 console.info('Prepared private test settings for a two-hour window. No live changes made.');
} catch {console.error('Preparation refused: check closed staging inputs, account/device UUIDs and a new output path. Details withheld.');process.exitCode=1;}
