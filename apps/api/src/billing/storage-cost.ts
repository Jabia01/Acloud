// Planning estimate only: excludes replicas, versions, thumbnails, traffic, tax and compute.
export function storageCostSettings(e:NodeJS.ProcessEnv=process.env){
 const rate=Number(e.STORAGE_ESTIMATE_USD_PER_TB_MONTH??'6.95'),budget=Number(e.UNPAID_STORAGE_BUDGET_USD_MONTH??'50');
 if(!Number.isFinite(rate)||rate<=0||rate>1000||!Number.isFinite(budget)||budget<=0||budget>1000000)throw new Error('Invalid storage cost estimate settings');
 return{rate,budget};
}
export async function storageCostEstimate(db:{query:Function}){
 const row=(await db.query(`SELECT count(*) FILTER(WHERE d.protected_bytes>COALESCE(m.quota_bytes,e.quota_bytes))::int AS "overQuotaAccounts",
 COALESCE(sum(GREATEST(d.protected_bytes-COALESCE(m.quota_bytes,e.quota_bytes),0)),0)::text AS "excessBytes",
 COALESCE(sum(CASE WHEN e.source='SUBSCRIPTION' THEN GREATEST(d.protected_bytes-COALESCE(m.quota_bytes,e.quota_bytes),0) ELSE 0 END),0)::text AS "paidExcessBytes",
 COALESCE(sum(CASE WHEN e.source='FREE' THEN d.protected_bytes ELSE 0 END),0)::text AS "freeAccountBytes"
 FROM entitlements e JOIN development_entitlements d ON d.user_id=e.user_id LEFT JOIN manual_entitlements m ON m.user_id=e.user_id AND (m.expires_at IS NULL OR m.expires_at>now())`)).rows[0];
 const {rate,budget}=storageCostSettings();const excess=Number(row.excessBytes),free=Number(row.freeAccountBytes),paidExcess=Number(row.paidExcessBytes);
 if(!Number.isSafeInteger(excess)||!Number.isSafeInteger(free)||!Number.isSafeInteger(paidExcess))throw new Error('Storage cost estimate unavailable');
 return{...row,rateUsdPerTbMonth:rate,estimatedExcessUsdMonth:excess/1e12*rate,estimatedFreeAccountUsdMonth:free/1e12*rate,budgetUsdMonth:budget,estimatedUnpaidUsdMonth:(free+paidExcess)/1e12*rate,budgetExceeded:(free+paidExcess)/1e12*rate>=budget,automaticDeletionEnabled:false};
}
