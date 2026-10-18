import React from 'react';import {renderToStaticMarkup} from 'react-dom/server';import {AdminPanel} from '../components/admin-panel';
import test from 'node:test';import assert from 'node:assert/strict';
import {staffSections,staffCanMutate,type Staff} from '../lib/admin';
const owner:Staff={id:'generated-owner',email:'owner@example.invalid',role:'SUPERADMIN',status:'ACTIVE',ownerReadOnly:true,readOnlyExpiresAt:'2030-01-01T00:00:00Z'};
test('owner preview exposes only requested metadata sections',()=>{assert.deepEqual(staffSections(owner),['overview','users','uploads','storage','devices','security','system','audit']);assert.equal(staffCanMutate(owner),false);for(const section of ['admins','billing','beta','lifecycle'])assert.ok(!staffSections(owner).includes(section));});
test('ordinary staff navigation and capabilities remain unchanged',()=>{assert.equal(staffCanMutate({...owner,ownerReadOnly:undefined}),true);assert.ok(staffSections({...owner,ownerReadOnly:undefined}).includes('admins'));assert.equal(staffCanMutate({...owner,role:'READ_ONLY_OPS',ownerReadOnly:undefined}),false);});

test("owner panel identifies read-only access while retaining sign-out",()=>{const html=renderToStaticMarkup(React.createElement(AdminPanel,{section:"overview",staff:owner}));assert.ok(html.includes("Owner preview"));assert.ok(html.includes("Read-only"));assert.ok(html.includes("sign out"));assert.ok(!html.includes("Create staff admin"));});
