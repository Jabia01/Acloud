# Architecture

ACL-001 implements the engineering foundation; ACL-002 adds server-side accounts,
opaque sessions, device registration and recovery, documented in AUTHENTICATION.md.
Acloud is the working name
for a privacy-focused media backup platform initially aimed at iPhone users in
Nigeria. Internal packages, schemas, services and contracts use neutral names;
a rename should affect display configuration, bundle IDs, domains and copy.

Intended future architecture:

```text
iOS App -> API -> PostgreSQL
              -> Private Object Storage
              -> Background Workers

Website -> API -> Subscription / entitlement system
```

The API owns identity, authorization, quota reservation, media metadata and
entitlements. PostgreSQL holds authoritative state. Private object storage holds
original bytes. Workers verify stored objects, reconcile interrupted uploads
and perform auditable maintenance. The website will sell storage; the native
app contains no payment processing. Verified, idempotent server-side payment
events will update entitlements; clients never determine payment status.

Future uploads should use direct-to-object-storage transfers rather than proxy
large media files through the API whenever safely possible. The API will issue
short-lived, user/object-scoped authorizations after quota reservation. A client
completion notification is a claim, not proof. Workers must independently check
object presence, expected size, checksum and ownership before PROTECTED. Plan
resumable/multipart transfers, retry budgets, deduplication without cross-user
disclosure, and reconciliation of abandoned reservations for unreliable and
expensive networks. Download/restore access must also be scoped and temporary.

Current implementation: npm workspaces, a Next.js App Router web shell, a NestJS
API, a pg connection pool, PostgreSQL 17 in local Docker Compose, and a SwiftUI
scaffold generated from XcodeGen. The shared TypeScript package defines only the
public health contract and its runtime validation. Swift decodes that contract
independently; contract tests are required when it changes.

GET /health returns {status, checks: {api, database}}, using HTTP 200 for healthy
and 503 for database failure. It checks database availability with SELECT 1,
does not assert migration currency, and reveals no hostnames, versions or errors.
The web status page calls it server-side, avoiding browser CORS and keeping API
configuration private. Health failures are bounded by connection/query timeouts.

Migrations are ordered SQL files tracked by name and SHA-256 checksum, applied
in a single transaction under an advisory lock. Do not edit applied migrations.
ACL-001 created only migration history and foundation metadata. ACL-002 adds
users, sessions, devices, verification/reset tokens and an initial auth audit
trail in the additive 002_accounts migration. The runner fails closed on checksum mismatch. Forward migrations are
preferred; no automatic down migration or destructive reset is provided.

Docker persists the database in a named volume and binds ports to localhost.
The optional API profile builds from the monorepo and runs migrations before
startup. Host development runs API and web separately for a small dependency
surface. ACL-002 adds a loopback-only local SMTP/mail sink and minimal auth forms,
with browser HttpOnly-cookie and iOS Keychain boundaries. No production infrastructure, payments, object storage,
PhotoKit, background workers or uploads are implemented.

Framework references: [Next.js setup](https://nextjs.org/docs/app/getting-started/installation),
[NestJS setup](https://docs.nestjs.com/first-steps).
