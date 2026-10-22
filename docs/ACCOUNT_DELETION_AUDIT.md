# Account deletion audit — 22 October 2026

## Scope and release state

Local implementation and generated-data verification only. This work does not activate account deletion, retention execution, payment admission or any hosted destructive operation. Key rotation remains pending separately. No real account was deleted, subscription cancelled or customer file accessed during this audit.

The iOS Account tab now links directly to `/account/delete` on the configured staging website. Website authentication is required separately; no native bearer or account identifier is placed in the URL. This is a web-based deletion entry, not an in-app native deletion API. Physical-device/browser acceptance and final distribution review remain pending.

## Findings and changes

1. **Renewal could survive a cancelled deletion.** The deletion request previously set the local subscription cancellation flag but relied on the deletion worker to stop the provider subscription. Cancelling deletion before that worker ran retired its jobs. The request now creates a separate durable `billing_provider_jobs` record for the exact existing provider subscription, in the same transaction as the request. Cancellation of deletion leaves this billing work intact. Billing reconciliation retries provider failures and records completion idempotently; it does not restart renewal or issue a refund.
2. **The website offered a form while deletion was unavailable.** An authenticated, read-only availability endpoint reports whether request/execution policy and the account-deletion/privacy-worker pause gates permit the self-service path. The form stays hidden while checking, unavailable or unverified. Availability is advisory; existing server authorization and execution checks remain authoritative. No feature switches are enabled by this change.
3. **The app had no direct deletion entry.** Account privacy now has a clearly named Delete account link to the dedicated page. The page verifies and identifies the signed-in account before offering a form and preserves its destination through website sign-in.
4. **Reauthentication failures could sign out a valid browser session.** The privacy proxy now retains the session cookie on failed deletion/export password checks and invalid public cancellation/status capabilities. Authenticated GET failures still clear an expired session. Server access checks are unchanged.
5. **Cancellation details were hard to use.** The page explains which cloud data is removed, device originals, sign-out, renewal cancellation, retained records and backup-copy expiry. It shows the configured cooling-off period and readable dates/status. The private cancellation code can be revealed explicitly, remains in component memory, and is never placed in a URL or browser storage. Existing requests without a reissued code point to saved details/support. Ambiguous network responses do not claim success.

## Existing safeguards confirmed by source review and generated-data tests

- Password reauthentication, explicit typed confirmation, account/session ownership and idempotency.
- Session revocation, disabled account access and failed outstanding checkouts on an accepted request.
- Cooling-off protection and authenticated private cancellation capability, with no reopening of old sessions.
- Exact storage binding and version inventory before deletion, including compound media resources; unproven versions require review.
- Independent encrypted inventory/tombstones, audit events, worker leases, provider retry and reconciliation after uncertain acknowledgements.
- Legal/security holds stop execution; subscription failure or over-quota state does not authorize deletion.
- Final minimization of account identifiers, device metadata, private previews, export payloads and capability records. Necessary billing/security/deletion evidence follows separately approved retention policies.
- Recovery from an actual generated PostgreSQL dump replays deletion tombstones and restricts restored data before exact-version cleanup.

## Remaining acceptance work

- Hosted self-service deletion is still gated. Review retention/operator procedures and independently stored deletion-ledger readiness before activation. Request intake alone is not proof that destructive processing is operating.
- Verify billing provider credentials and the billing/privacy worker paths in the intended environment. Provider outage or disabled reconciliation can leave cancellation pending; completion must not be inferred from a local flag.
- Complete a disposable hosted-account deletion drill, renewal cancellation confirmation, cancellation-window test and physical iPad navigation check after authorized publication/activation. Do not use the owner's real account as a deletion fixture.
- Backup copies expire under the approved backup schedule; the workflow does not promise immediate physical removal from every historical backup. Tombstone recovery is a required operational step.
- A lost one-time cancellation code is not regenerated; privacy support needs a verified recovery procedure. No support authentication bypass is introduced here.

Verification passed: 156 generated-data database/lifecycle/billing tests, 29 API unit tests, 149 website tests, API compilation, website production build (including `/account/delete`), native simulator build, and secret scanning with no unexpected findings. The disposable PostgreSQL container and temporary credentials were removed. API health test setup initially exceeded its five-second limit during simultaneous builds; all 29 tests passed on rerun after those builds finished. The billing failure fixture was corrected to simulate cancellation outages before its regression passed. Logs are retained in the local project-audit handoff. This audit is engineering evidence, not legal/retention approval or App Store acceptance.
