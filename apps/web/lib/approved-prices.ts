// Owner-approved NGN catalogue, 19 October 2026. Amounts below are whole naira.
// Display only: checkout must match an active server-side price and Paystack plan.
export const approvedStoragePrices = [
 {code:'FREE_5',displayName:'5 GB Free',quotaBytes:'5000000000',monthly:0,annual:0},
 {code:'STANDARD_32',displayName:'32 GB',quotaBytes:'32000000000',monthly:599,annual:5990},
 {code:'STANDARD_64',displayName:'64 GB',quotaBytes:'64000000000',monthly:999,annual:9990},
 {code:'STANDARD_128',displayName:'128 GB',quotaBytes:'128000000000',monthly:1999,annual:19990},
 {code:'STANDARD_256',displayName:'256 GB',quotaBytes:'256000000000',monthly:3499,annual:34990},
 {code:'STANDARD_512',displayName:'512 GB',quotaBytes:'512000000000',monthly:6499,annual:64990},
 {code:'STANDARD_1TB',displayName:'1 TB',quotaBytes:'1000000000000',monthly:10999,annual:109990},
 {code:'STANDARD_2TB',displayName:'2 TB',quotaBytes:'2000000000000',monthly:21999,annual:219990},
] as const;
