import {test} from 'node:test';import assert from 'node:assert/strict';import {storageCostSettings,storageCostEstimate} from '../src/billing/storage-cost';
test('storage estimate rejects unsafe configuration and keeps deletion disabled',async()=>{
 assert.deepEqual(storageCostSettings({}),{rate:6.95,budget:50});for(const rate of ['NaN','-1','Infinity','0'])assert.throws(()=>storageCostSettings({STORAGE_ESTIMATE_USD_PER_TB_MONTH:rate}));
 const result=await storageCostEstimate({query:async()=>({rows:[{overQuotaAccounts:1000,excessBytes:'168000000000000',paidExcessBytes:'0',freeAccountBytes:'200000000000000'}]})});
 assert.equal(result.estimatedExcessUsdMonth,1167.6000000000001);assert.equal(result.estimatedFreeAccountUsdMonth,1390);assert.equal(result.budgetExceeded,true);assert.equal(result.automaticDeletionEnabled,false);
});
