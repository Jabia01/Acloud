import React from 'react';import {renderToStaticMarkup} from 'react-dom/server';import {AdminPanel} from '../components/admin-panel';
import test from 'node:test';import assert from 'node:assert/strict';
import {staffSections,staffCanMutate,type Staff} from '../lib/admin';
const owner:Staff={id:'generated-owner',email:'owner@example.invalid',role:'SUPERADMIN',status:'ACTIVE',ownerReadOnly:true,readOnlyExpiresAt:'2030-01-01T00:00:00Z'};
test('owner preview exposes only requested metadata sections',()=>{assert.deepEqual(staffSections(owner),['overview','users','uploads','storage','devices','security','system','audit']);assert.equal(staffCanMutate(owner),false);for(const section of ['admins','billing','beta','lifecycle'])assert.ok(!staffSections(owner).includes(section));});
test('ordinary staff navigation and capabilities remain unchanged',()=>{assert.equal(staffCanMutate({...owner,ownerReadOnly:undefined}),true);assert.ok(staffSections({...owner,ownerReadOnly:undefined}).includes('admins'));assert.equal(staffCanMutate({...owner,role:'READ_ONLY_OPS',ownerReadOnly:undefined}),false);});

test("owner panel identifies read-only access while retaining sign-out",()=>{const html=renderToStaticMarkup(React.createElement(AdminPanel,{section:"overview",staff:owner}));assert.ok(html.includes("Owner preview"));assert.ok(html.includes("Read-only"));assert.ok(html.includes("sign out"));assert.ok(!html.includes("Create staff admin"));});

import {AdminFrame} from '../components/admin-frame';
import {SafeAdminTable,AdminMetrics,ServiceHealth} from '../components/admin-panel';
test('owner frame highlights current section and excludes restricted navigation',()=>{const html=renderToStaticMarkup(React.createElement(AdminFrame,{staff:owner,section:'system',children:React.createElement('h1',{id:'admin-title'},'System')}));assert.ok(html.includes('aria-current="page"'));assert.ok(html.includes('System health'));assert.ok(html.includes('Owner preview'));for(const path of ['/admin/admins','/admin/beta','/admin/billing','/admin/lifecycle'])assert.ok(!html.includes('href="'+path+'"'));});
test('operational dates have explicit timezone',()=>{const html=renderToStaticMarkup(React.createElement(SafeAdminTable,{columns:['createdAt','status'],rows:[{createdAt:'2026-10-18T18:00:00Z',status:'PROTECTED'}]}));assert.ok(html.includes('dateTime="2026-10-18T18:00:00Z"'));assert.ok(html.includes('UTC'));assert.ok(html.includes('Protected'));});
test('metrics retain explicit missing values without inventing other measurements',()=>{const html=renderToStaticMarkup(React.createElement(AdminMetrics,{data:{totalUsers:0,protectedBytes:null}}));assert.ok(html.includes('Total Users'));assert.ok(html.includes('Unavailable'));assert.ok(!html.includes('Failed Uploads'));});

test('service health never represents missing health as healthy',()=>{const html=renderToStaticMarkup(React.createElement(ServiceHealth,{data:{api:'UP',database:'UNAVAILABLE'}}));assert.ok(html.includes('Reachable'));assert.ok(html.includes('Unavailable'));assert.ok(html.includes('Not confirmed'));assert.equal((html.match(/service-dot up/g)||[]).length,1);});
