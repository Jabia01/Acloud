import test from 'node:test';import assert from 'node:assert/strict';import {ThumbnailCache,ThumbnailLoadError} from '../lib/thumbnail-cache';
const jpeg=()=>new Response(new Uint8Array([255,216,255,217]),{headers:{'Content-Type':'image/jpeg'}});
test('grid and viewer deduplicate pending requests and reuse bounded small blobs',async()=>{
 let count=0;const cache=new ThumbnailCache((async()=>{count++;return jpeg()}) as typeof fetch);
 const [a,b]=await Promise.all([cache.load('version-a','asset'),cache.load('version-a','asset')]);assert.equal(a,b);assert.equal(count,1);assert.equal(await cache.load('version-a','asset'),a);assert.equal(count,1);
 await cache.load('version-b','asset');assert.equal(count,2);cache.clear();await assert.rejects(cache.load('version-a','asset'));
});
test('loads at most three concurrent images even with a large gallery',async()=>{
 let active=0,max=0;const cache=new ThumbnailCache((async()=>{active++;max=Math.max(max,active);await new Promise(r=>setTimeout(r,10));active--;return jpeg()}) as typeof fetch);
 await Promise.all(Array.from({length:15},(_,i)=>cache.load('key'+i,'asset'+i)));assert.equal(max,3);cache.clear();
});
test('missing derivatives are negatively cached temporarily and retried without originals',async()=>{
 let now=0,count=0;const cache=new ThumbnailCache((async(url)=>{assert.match(String(url),/^\/api\/media-thumbnail\//);count++;return count===1?new Response(null,{status:404}):jpeg()}) as typeof fetch,()=>now);
 await assert.rejects(cache.load('v','a'),(e:unknown)=>e instanceof ThumbnailLoadError&&e.status===404);await assert.rejects(cache.load('v','a'));assert.equal(count,1);now=61000;await cache.load('v','a');assert.equal(count,2);cache.clear();
});
test('permission denial is not retried and responses must be small JPEGs',async()=>{
 let count=0;const denied=new ThumbnailCache((async()=>{count++;return new Response(null,{status:403})}) as typeof fetch);await assert.rejects(denied.load('v','a'));assert.equal(count,1);denied.clear();
 for(const response of [new Response('bad',{headers:{'Content-Type':'text/html'}}),new Response(new Uint8Array(40961),{headers:{'Content-Type':'image/jpeg'}})]){const cache=new ThumbnailCache((async()=>response) as typeof fetch);await assert.rejects(cache.load('v','a'));cache.clear()}
});
test('disposing a frame cancels pending loads and isolates the next account cache',async()=>{
 const old=new ThumbnailCache((async(_url,init)=>new Promise<Response>((_resolve,reject)=>init?.signal?.addEventListener('abort',()=>reject(new Error('aborted'))))) as typeof fetch);
 const jobs=Array.from({length:5},(_,i)=>old.load('k'+i,'a'+i));old.clear();await Promise.all(jobs.map(p=>assert.rejects(p)));
 const next=new ThumbnailCache((async()=>jpeg()) as typeof fetch);await next.load('k0','a0');next.clear();
});
