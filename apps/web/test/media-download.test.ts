import {test} from 'node:test';import assert from 'node:assert/strict';
import {upstreamDownloadPath,downloadNavigationAllowed,authorizeOriginalDownload,originalDownloadPath,resourceDownloadPath,DownloadError} from '../lib/media-download';
import {safeDownload} from '../lib/control';
const id='11111111-1111-4111-8111-111111111111',api='https://api.generated.invalid',storage='https://storage.generated.invalid';
test('browser download routes accept only owned asset/resource identifiers without locators',()=>{
 assert.equal(upstreamDownloadPath(['assets',id]),`/assets/${id}/download`);assert.equal(upstreamDownloadPath(['manifests',id,'resources',id]),`/media-manifests/${id}/resources/${id}/download`);
 assert.equal(originalDownloadPath(id),'/api/media-download/assets/'+id);assert.ok(resourceDownloadPath(id,id).includes(id));
 for(const bad of [['assets','../private'],['assets',id,'download'],['https://evil.invalid'],['manifests',id,'objects',id]])assert.equal(upstreamDownloadPath(bad),null);
});
test('download navigation rejects cross-origin triggers and allows explicit library navigation',()=>{
 const req=(headers:Record<string,string>)=>new Request('https://web.generated.invalid/api/media-download/assets/'+id,{headers});
 assert.equal(downloadNavigationAllowed(req({'sec-fetch-site':'same-origin'}),'https://web.generated.invalid'),true);
 assert.equal(downloadNavigationAllowed(req({'sec-fetch-site':'none','sec-fetch-mode':'navigate'}),'https://web.generated.invalid'),true);
 assert.equal(downloadNavigationAllowed(req({referer:'https://web.generated.invalid/photos'}),'https://web.generated.invalid'),true);
 for(const site of ['cross-site','same-site'])assert.equal(downloadNavigationAllowed(req({'sec-fetch-site':site,referer:'https://web.generated.invalid/photos'}),'https://web.generated.invalid'),false);
 assert.equal(downloadNavigationAllowed(req({referer:'https://evil.invalid/photos'}),'https://web.generated.invalid'),false);
});
test('fresh download authorization is a no-store empty POST; only trusted private storage is used',async()=>{
 let calls=0;const fetcher=(async(url:unknown,init:RequestInit)=>{calls++;assert.equal(String(url),api+`/assets/${id}/download`);assert.equal(init.method,'POST');assert.equal(init.body,'{}');assert.equal(init.cache,'no-store');assert.equal(init.redirect,'error');return Response.json({method:'GET',url:storage+'/bucket/generated?versionId=one',expiresAt:new Date(Date.now()+60000).toISOString()})}) as typeof fetch;
 const grant=await authorizeOriginalDownload({path:`/assets/${id}/download`,token:'generated',apiBase:api,storageOrigin:storage,signal:new AbortController().signal,fetcher});assert.ok(grant.url.startsWith(storage));assert.equal(calls,1);
 const foreign=(async()=>Response.json({method:'GET',url:'https://evil.invalid/private',expiresAt:new Date(Date.now()+60000).toISOString()})) as typeof fetch;
 await assert.rejects(authorizeOriginalDownload({path:`/assets/${id}/download`,token:'generated',apiBase:api,storageOrigin:storage,signal:new AbortController().signal,fetcher:foreign}));
});
for(const status of [401,403,404,409,429,500])test(`download failure ${status} remains explicit and hides upstream details`,async()=>{
 const fetcher=(async()=>new Response('PRIVATE_PROVIDER_BODY',{status})) as typeof fetch;
 await assert.rejects(authorizeOriginalDownload({path:`/assets/${id}/download`,token:'generated',apiBase:api,storageOrigin:storage,signal:new AbortController().signal,fetcher}),e=>e instanceof DownloadError&&e.status===(status===500?503:status)&&!e.message.includes('PRIVATE'));
});
test('invalid dates and URL fragments never become download links',()=>{const grant={method:'GET',url:storage+'/file',expiresAt:'invalid'};assert.equal(safeDownload(grant),null);assert.equal(safeDownload({...grant,url:storage+'/file#secret',expiresAt:new Date(Date.now()+60000).toISOString()}),null)});
