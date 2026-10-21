# Website downloads and account exports — 21 October 2026

## Original files

The Photos/Videos viewer and file details use explicit download links. Each click calls the same-origin server route, which obtains a fresh, short-lived API capability and redirects directly to trusted private storage. The website does not buffer originals. Selection offers separate links, up to five files and 500 MiB selected, rather than launching automatic downloads that browsers may block. This is not a ZIP download.

The private owner test permits a live web device session belonging to the approved account to read protected source-device assets within the existing account/device/resource binding, test window, file-size limits and download switch. It grants no upload or Photos restore authority and does not extend the window. Revocation, protection state, private-bucket binding and pinned versions remain checked. Known manifest UTIs determine safe attachment extensions; unidentified formats use .bin rather than an invented image format.

Permission, expired-session, missing-file and temporary-service failures produce explicit error pages without revealing provider responses or capabilities. No permanent public file URL is created.

## Account information

Account → Your data and privacy → Download your account information requests an export after password reauthentication. Recent requests survive refresh. The selected request polls a manifest-only endpoint every five seconds during preparation, stopping when ready, failed or expired. Transient polling errors retry after fifteen seconds. Checking status does not decrypt or download account rows.

Prepare account download verifies the request-bound manifest, each chunk capability, sequence, category, SHA-256 and record count before creating a browser file. The user then clicks Save file. Individual NDJSON files remain available when the combined 32 MiB limit is exceeded. Export metadata excludes original photo/video bytes; originals are downloaded through Photos/Videos separately. Preparing or saving an export does not cancel billing or delete data.

The export worker advances at most four existing bounded slices per turn. Exhausted retries or worker leases mark the scoped request failed so it cannot remain preparing indefinitely or consume an active-export slot. No retention or deletion controls are enabled by this change.

## Validation

Generated fixtures only; no customer originals or account exports downloaded. Website regression suite: 140 passing. Storage suite: 60 passing. Generated PostgreSQL lifecycle/hardening/export tests: 113 passing; scoped owner-device suite: 47 passing after fixture corrections. The real browser acceptance verified automatic export polling, integrity-checked JSON save, fresh capability redirect to a generated storage attachment, and explicit permission failure feedback. API and production website builds checked separately.

## Deployment and acceptance

No migration or configuration expansion is required. Deploy API and worker before the website because the website uses the new manifest-only endpoint. Do not extend owner-test access or turn on global beta/deletion/payment controls. After deployment, verify a photo, video and compound-media resource from the approved browser account and an account-information request. Local browser fixtures establish the save flow, not hosted customer acceptance. iPad reinstall is unnecessary for these web/backend changes.
