import {test} from 'node:test';import assert from 'node:assert/strict';
import {loginDestination,loginRecoveryFields,browserDeviceIdentifier} from '../lib/login-recovery';
import {LibrarySnapshots} from '../lib/library-snapshot';
test('checkout return destinations remain local, allowlisted and strip untrusted query parameters',()=>{
 for(const path of ['/billing/success','/billing/cancel','/account/delete','/sessions','/photos'])assert.equal(loginDestination(path),path);
 for(const path of ['https://evil.invalid','//evil.invalid','/billing/success?redirect=evil','/admin',null])assert.equal(loginDestination(path),'/dashboard');
 assert.equal(loginRecoveryFields(409,'login'),true);assert.equal(loginRecoveryFields(401,'login'),false);assert.equal(loginRecoveryFields(409,'register'),false);
});
test('browser identity is reused; malformed storage is replaced with a fresh non-secret identifier',()=>{
 const id='11111111-1111-4111-8111-111111111111';let value:string|null=id;const storage={getItem:()=>value,setItem:(_k:string,v:string)=>{value=v}};
 assert.equal(browserDeviceIdentifier(storage,()=>{throw Error('must reuse')}),id);value='malformed';assert.equal(browserDeviceIdentifier(storage,()=>id),id);assert.equal(value,id);
});
test('library snapshots retain successful empty results and isolate account-scoped instances',()=>{
 const first=new LibrarySnapshots(),other=new LibrarySnapshots(),inventory={items:[],nextCursor:null};first.set('photos:',inventory,100);
 assert.equal(first.get('photos:',101)?.inventory,inventory);assert.equal(other.get('photos:',101),null);assert.equal(first.get('videos:',101),null);
 first.set('account:',inventory,100);assert.equal(first.get('account:',101),null);assert.equal(first.get('photos:',1800101),null);
 first.set('photos:',inventory);first.clear();assert.equal(first.get('photos:'),null);
});
