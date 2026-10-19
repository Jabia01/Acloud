# Paystack staging setup and acceptance

Prepared locally; no keys, price activation, charge or hosted migration is implied.

## Prepared implementation

Website-only hosted checkout, signed raw-body webhook validation, server-side transaction verification, idempotent payment evidence, immutable price versions, monthly/annual subscriptions, cancellation, grace periods and reconciliation already exist. This update adds the unpriced STANDARD_32 catalogue tier (32,000,000,000 bytes), payment availability UI, disabled checkout until configuration/acceptance is ready, exact canonical Paystack plan validation, and clearer plan/price confirmation and status refresh.

Apply additive migration 017 after 016 during an explicitly authorized deployment. It creates no price and changes no existing customer entitlement, quota, protected file or subscription. Do not edit already-applied migration 007.

## Inputs still needed

- Owner approved the NGN display catalogue below on 19 October 2026. Configure matching immutable server-side price versions and Paystack plan codes before activation; displayed amounts alone do not enable checkout.
- Paystack TEST secret key in Railway API and billing worker secret settings, never in a browser variable, native application, Git, issue, screenshot or chat transcript.
- Canonical Paystack plan codes for each approved monthly/annual price, with matching currency/amount/interval/TEST domain. Create immutable billing_prices versions; leave inactive until operator approval and provider validation. Do not overwrite past prices.
- Paystack dashboard webhook registration: https://api-staging.useacloud.com/billing/webhooks/paystack
- Fixed browser return: https://staging.useacloud.com/billing/success

The current backend integration uses the server secret key, not an embedded client SDK/public key. The webhook signature uses that same Paystack secret; do not invent an independent webhook signing secret.

## Activation sequence

1. Keep BILLING_ENABLED=false while installing code and migration. Review prices and TEST plan mappings.
2. Restricted OWNER_DEVICE_TEST mode intentionally requires payments off. Moving to payment testing needs the approved beta configuration; do not silently remove its safeguards or mark acceptance evidence PASS.
3. Set PAYSTACK_ENVIRONMENT=TEST and a TEST key. Staging never accepts a live key. Validate Paystack account readiness and supported recurring card payments.
4. Complete PAYSTACK, APPROVED_PRICES, BILLING_REVIEW, WEBHOOK, BILLING_WORKER, PAYMENT_SUPPORT and mandatory beta acceptance requirements. Open the intended checkout/billing-worker switches only with real evidence. Readiness reflects these gates; it does not create evidence or enable them.
5. In the authorized payment test environment, configure BILLING_ENABLED, BETA_ENABLED and BETA_ALLOW_PAYMENTS deliberately. Verify API and worker share matching settings and immutable price rows; validate remote plans before any test checkout.
6. Exercise TEST checkout, signed successful webhook, matching amount/currency/customer/domain, idempotent replay and server quota replacement. Confirm the return URL alone cannot activate capacity.
7. Verify reconciliation recovers a delayed webhook, renewal provisioning uses reusable authorization, cancellation retains paid capacity until period end, failures preserve protected media, and stale/out-of-order events do not regress newer entitlements.

The first period is a one-off exact-price card checkout; recurrence is provisioned only after verified evidence. A lower-capacity purchase schedules the change at the current period end. Clearly disclose this behavior before a paid release. No real customer billing is accepted until live configuration, prices and acceptance are explicitly approved.

Official references: https://paystack.com/docs/payments/webhooks/ , https://paystack.com/docs/payments/subscriptions/ , https://paystack.com/docs/api/plan/ .

## Owner-approved NGN catalogue — 19 October 2026

| Plan | Monthly (NGN) | Annual (NGN) |
| --- | ---: | ---: |
| Free 5 GB | 0 | 0 |
| 32 GB | 599 | 5,990 |
| 64 GB | 999 | 9,990 |
| 128 GB | 1,999 | 19,990 |
| 256 GB | 3,499 | 34,990 |
| 512 GB | 6,499 | 64,990 |
| 1 TB | 10,999 | 109,990 |
| 2 TB | 21,999 | 219,990 |

Annual is ten monthly payments (two months free), billed annually. Paystack minor-unit values are exactly the figures above multiplied by100. Display catalogue source: apps/web/lib/approved-prices.ts. Prices are display-only until matching active server price rows, canonical provider plan codes and readiness/acceptance are configured. The UI blocks mismatched, missing or ambiguous provider prices. Do not insert invented Paystack plan codes or replace historical immutable price rows.
