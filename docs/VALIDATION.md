# Foundation validation record

## ACL-003M-A: limited-library picker compile repair

User-reported native environment: Xcode 26.3, Swift 6.2.4, Intel Mac,
macOS Sequoia 15.7.9. Reported diagnostic (approximate, not a captured build log):
`Value of type 'PHPhotoLibrary' has no member 'presentLimitedLib...'` in
PhotoKitLibrary.swift. The failing call was
`PHPhotoLibrary.shared().presentLimitedLibraryPicker(from:controller) { _ in completion() }`.

Source diagnosis: the file imported Photos and UIKit, but omitted **PhotosUI**,
which exposes the limited-picker extension of PHPhotoLibrary. Apple's
[limited-library sample](https://developer.apple.com/videos/play/wwdc2020/10641/)
imports PhotosUI for this call. The
[completion-handler overload](https://developer.apple.com/documentation/photos/phphotolibrary/presentlimitedlibrarypicker(from:completionhandler:))
is available on iOS/iPadOS/Mac Catalyst 15+, verified against Apple's public
documentation metadata. This is a missing framework import, not an Intel
architecture or deployment-version workaround. Diagnosis matches inspected
source and reported error; successful recompilation remains unverified here.

Repair: moved the existing PhotoLibraryAccessUI public adapter to
`Sources/PhotoKitDiscovery/PhotoLibraryAccessUI.swift`, guarded by
`os(iOS) && canImport(UIKit) && canImport(PhotosUI)`. The adapter imports Photos,
PhotosUI and UIKit; uses the explicit supported `completionHandler:` overload;
has `@available(iOS 15.0, *)`; and delivers its Sendable completion on MainActor.
The SwiftUI picker completion signature carries those same actor/Sendable
requirements. Removed UIKit and presentation code from PhotoKitLibrary.swift;
authorization/scanning/change observation/persistence are unchanged. No private
API, selector, KVC, missing-feature stub or deployment relaxation was added.

Verified configuration: app deployment iOS 17.0; package platforms iOS 17 and
macOS 13. PhotoKitLibrary remains under `#if os(iOS)`; the UIKit adapter is
excluded from native macOS package tests. Package source discovery automatically
includes the new Swift file; no project.yml dependency change is needed.
`PHPhotoLibraryPreventAutomaticLimitedAccessAlert: true` and the Photos usage
description are already correctly set in project.yml. The generated app plist
still needs verification after XcodeGen on the Mac.

This repair was performed in the existing **Windows C:/Acloud workspace**, not
on the user's Mac. `Get-Command swift,xcodebuild,xcodegen` found no native tools.
Therefore Xcode project regeneration, all iOS target builds and all 35 native
tests are **not executed** in this repair. No next native compile/test error was
observed; absence of another error is not a successful build claim. Native
commands and plist checks are in [IOS_VALIDATION_PLAN.md](IOS_VALIDATION_PLAN.md).
Source/config inspection and final credential-scan results are recorded below.
ACL-004 was not started; no commits/pushes occurred.

| Repair check executed on Windows | Result |
| --- | --- |
| Source/config review | PhotosUI/Photos/UIKit imports present in the adapter; explicit iOS/UIKit/PhotosUI guard; iOS 15 availability; iOS 17 app/package target preserved; manual limited-picker alert suppression true. |
| `npm.cmd run security:scan` | Exit 0; **99 Git-visible files**, **0 unexpected findings**, **4 reviewed local/test examples**. |
| `git diff --check` | Exit 0; only Git LF→CRLF normalization warnings, no whitespace errors. |
| XcodeGen / iOS Debug+Release simulator/device builds | **Not executed**; tools unavailable in this Windows workspace. |
| DiscoveryCore / HealthClient native tests | **0 executed**; 24 + 11 authored tests await the Mac. |

## ACL-003: local iPhone photo-library discovery

Executed on 2026-10-01 in C:/Acloud on Windows, Node.js v24.16.0 / npm 11.17.0.
This record supersedes prior stages for current Windows regressions; earlier
records remain historical. ACL-003 implementation and authored native tests are
**not native-validated**. No Swift compiler, Xcode, simulator, PhotoKit execution,
XCTest execution, device SQLite/Data Protection testing or native performance
benchmark ran. No ACL-004, upload, media transfer/modification/deletion, cloud
storage, payments, subscriptions or production infrastructure was introduced.
No commit or push was made.

### Exact executed results

| Command/check | Result actually observed |
| --- | --- |
| Existing Docker Compose `up -d --wait --wait-timeout 60 db mail` | Exit 0; PostgreSQL and Mailpit healthy. Docker per-user bin added to this shell's PATH; no configuration/credential output. |
| Compose `ps --format '{{.Name}} {{.State}} {{.Health}}'` | Exit 0; media-backup-dev-db-1 running healthy; media-backup-dev-mail-1 running healthy. |
| `npm.cmd run db:migrate` | Exit 0; **0 applied**. Existing 001/002 migrations remain applied; no ACL-003 server migration added. |
| Immediate second migration run | Exit 0; **0 applied**. |
| `npm.cmd test` | Exit 0; **24 passed, 0 failed**: 3 migration mocks, 1 shared test, 15 API Jest tests across 5 suites, 5 web tests. |
| `npm.cmd run build` | Exit 0; shared TypeScript, API TypeScript and web Next.js production compilation/typecheck/static generation succeeded. |
| `npm.cmd run test:integration` | Exit 0; **21 passed, 0 failed, 0 skipped**: 20 real PostgreSQL account-security tests plus foundation migration/HTTP-health integration test. Fresh isolated test schema migration apply/rerun and HTTP database reachable check passed. |
| Initial `npm.cmd run test:auth:live` | Exit 1 at GET /health: API was not running. No live success claimed for this attempt. |
| Built API start | `node --env-file=../../.env dist/main.js` from apps/api; observed listening on 3001. |
| Built web start | `node ../../node_modules/next/dist/bin/next start` from apps/web; observed ready on 3000. |
| Repeated `npm.cmd run test:auth:live` | Exit 0; registration/duplicate suppression/hash storage, login/me, actual Mailpit verification/reset capture, replay rejection, session/device/logout revocation, six web pages, Origin rejection, cookie safety/no browser bearer and authenticated account/logout passed. Temporary random .invalid development account retained with issued sessions revoked; no credentials logged. |
| `npm.cmd run security:scan` | Both scans exited 0. First: **97 Git-visible files**. Final: **98 Git-visible files**, **0 unexpected findings**, **4 reviewed local/test example lines**. Heuristic scanner is not a complete Git-history/security audit. Ignored local .env intentionally excluded. |
| Source search/static inspection | Reviewed Swift sources for UserDefaults, logging, media network/content/mutation APIs, localIdentifier usage, private size APIs, batches, permission request guards and limited-scope projections. Detailed findings below. |
| `git diff --check` | Exit 0. All repository files remain untracked/uncommitted, so this check does not prove whitespace/source review of untracked files. |
| `Get-Command swift,xcodebuild -ErrorAction SilentlyContinue` | No commands found. Native tests/builds **not executed**. |
| Temporary process cleanup | Verified process IDs/command lines and stopped only the API/web validation processes. PostgreSQL/Mailpit left running; volumes preserved. Initial process inventory required elevated access after normal-shell Access denied. |

Executed Node automated total: **45 passed, 0 failed**, plus successful live
HTTP/SMTP/web assertions after servers started. No new Node tests are counted
for the Swift discovery implementation. Existing database outage/stack-volume
persistence scenarios were validated during ACL-001B; those destructive service
interruptions were not repeated in ACL-003. Current migrations/health/account
integration did execute. PostgreSQL volumes were never removed.

### Authored native tests — unexecuted

24 DiscoveryCore XCTest cases cover all five permission states; image metadata;
video counts/duration; repeat-scan row/first-seen idempotence; new assets; removed
records retained unavailable; unknown sizes; mixed known/unknown aggregate;
cancellation with complete-batch checkpoint; same-snapshot resume; 100,001 assets
and 401 bounded batches; no protection states; no cloud-identity fields;
all-original-component size/overflow policy; permission-loss cache invalidation;
changed snapshots; cancelled rescan preserving unseen records; disk reopen/new
session re-scan; empty-library reconciliation; cancellation after permission loss
returning no cached counts. Existing 11 HealthClient tests are also unexecuted
here. Total native tests authored: **35**, executed on Windows: **0**.

### Static iOS privacy/security review

- Existing AccountView UserDefaults stores only backup_device_identifier. Auth
  bearer persistence remains in KeychainSessionStore. Discovery has no token store.
- Discovery core/PhotoKit adapter have no URLSession, media content/network APIs,
  PHAssetResourceManager, requestData/requestImage/requestAVAsset or PhotoKit
  mutation/deletion calls. Settings/picker UI uses Apple-supported local UI.
- No discovery print/NSLog/os_log/Logger output, thumbnails, filenames, paths,
  EXIF or original media are created/logged. The local DB necessarily contains
  private IDs/dates/dimensions and is intended to use complete protection and
  backup exclusion; actual device behavior remains pending.
- Application batch cap is 1,000 with default 250; no array of all Photos assets,
  repeated per-item duplicate scans or per-batch full-table aggregate. Native
  PHFetchResult framework memory is not measured here.
- RequestAuthorization only on explicit action while notDetermined; requests
  coalesced. No repeated denied/restricted prompt or attempt to expand access
  automatically. Limited set is fetched under PhotoKit authorization, labelled
  limited, and managed with the system picker. Foreground clears old counts.
- Static review found a cancellation path that could return cached partial counts
  after access/snapshot loss. Repaired by checking current authorization/revision
  before returning cancelled results and added an unexecuted regression test.
  Superseded progress callbacks are also suppressed during a pending refresh.
- Default resource sizes/availability remain unknown. Optional public dataSize
  metadata is iOS 27 SDK/runtime gated and OFF by default; no KVC/private fileSize
  fallback. Optional branch compilation/resource semantics remain pending.
- No protection/upload/cloud identity or server media persistence was added.
  Unavailable observations never authorize deletion of future backups.

### Remaining validation blockers

macOS/Xcode/real-iPhone execution is required: compile package/app, run all 35
native tests, verify permission/picker/Settings races, iCloud-optimized behavior,
counts/durations, protected SQLite/WAL/SHM/backup exclusion, restart/cancellation,
large-library memory/UI performance, optional newer-SDK size API and ACL-002
Keychain regression. Follow [IOS_VALIDATION_PLAN.md](IOS_VALIDATION_PLAN.md).
See [PHOTO_LIBRARY_DISCOVERY.md](PHOTO_LIBRARY_DISCOVERY.md) and
[ACL003_TREE.md](ACL003_TREE.md) for architecture and manual-review files.

## ACL-002: authentication and account foundation

Executed on 2026-10-01 in C:/Acloud on Windows, Node.js v24.16.0, npm 11.17.0,
Docker engine 29.8.1 / Compose v5.5.1, PostgreSQL 17, Next.js 16.3.8,
NestJS 11.2.7, argon2 0.45.1 and nodemailer 10.0.13. This is the latest account
validation record. Earlier ACL-001/001A/001B records below remain historical.
No ACL-003 feature, media/storage/upload/PhotoKit/payment/subscription feature,
external email provider, MFA/passkey/social login or production deployment was
implemented. No commits or remote pushes were made.

### Executed commands and exact results

| Check | Final executed result |
| --- | --- |
| Dependency installation | npm install for Argon2/nodemailer/types exited 0; final installation audited 472 packages and reported 0 vulnerabilities. Native Argon2 worked in the password tests on Windows. |
| Local Compose startup | `up -d --wait --wait-timeout 60 db mail` exited 0; PostgreSQL running healthy, Mailpit running healthy, SMTP 1025 and mailbox HTTP 8025 bound to loopback. |
| `npm.cmd run db:migrate` | Exit 0; **1 applied** (new 002_accounts.sql). |
| Immediate migration rerun | Exit 0; **0 applied**. Applied 001 SQL was not modified. |
| `npm.cmd test` | Exit 0; **24 passed, 0 failed**: migration mocks 3, shared health validator 1, API Jest 15 in 5 suites, web 5. |
| Password assertions | Argon2id v19, 65536 KiB, 3 iterations, 1 lane; salts differ; correct password passes; wrong and unknown-account verification fail; 18 admitted hashing jobs finish and a nineteenth simultaneous job is rejected by the bounded queue. |
| `npm.cmd run build` | Exit 0; shared and API TypeScript builds passed; Next.js production build compiled, type-checked and generated all six auth pages, /, /status, /_not-found and the dynamic cookie-proxy route. |
| `npm.cmd run test:integration` (final expanded run) | Exit 0; **21 passed, 0 failed, 0 skipped**: 20 account-security tests plus existing database-health integration test. Real local PostgreSQL used throughout. |
| Isolated migration integration | Both migration files applied in a fresh random test schema (**2 applied**); repeat runner returned **0 applied**. Fixture schema dropped after tests; application tables/customer data were not truncated or deleted. |
| `node scripts/validate-auth-live.mjs` | Exit 0; running built API + real SMTP/Mailpit + PostgreSQL flows passed. |
| `npm.cmd run test:auth:live` | Exit 0; repeated running API/SMTP/PostgreSQL flows and additionally validated six built web pages and live browser-cookie/CSRF proxy over HTTP. |
| `npm.cmd run security:scan` | Exit 0; **85 Git-visible files scanned; 0 unexpected findings; 4 reviewed local/test example lines**. Scanner expanded for hardcoded bearers, unsafe local/session/UserDefaults token storage and direct sensitive logging. |
| Manual source search | Reviewed password_hash/token_hash/sessionToken, console logging, localStorage/sessionStorage/UserDefaults references in application sources and the live validator. Only explicit login issuance, internal hashing, Keychain/cookie use, non-secret device IDs and credential-free status logs found. |
| `git diff --check` | Exit 0. Repository files remain uncommitted; this check does not substitute for reviewing untracked source. |
| Swift/XCTest/Keychain/simulator build | **Not executed**: Swift and Xcode are unavailable on Windows. 11 XCTest cases are authored (5 health, 5 auth networking, 1 actual Keychain roundtrip), pending macOS execution. |
| GitHub Actions / optional API Docker image | Workflow updated, neither executed in this task. Host API, built Next.js server and PostgreSQL/Mailpit Compose services were executed. |

Total executed automated Node tests: **45 passed, 0 failed** (24 unit/component
and 21 real PostgreSQL integration). Live HTTP/SMTP/browser-proxy assertions are
additional to this count. Web checks used HTTP requests against the running
built server; no interactive browser click-through or visual review was executed.

### Live account and recovery evidence

The live validator creates random .invalid local-development accounts and random
passwords, never printing the email credentials, passwords, tokens or mail URLs.
It queries real application tables to confirm Argon2id password storage and
SHA-256-only session/verification/reset token persistence. It actually executed:

- Registration and normalized duplicate registration with identical 202 public
  responses, exactly one account, and no verification token in either response.
- Login with device metadata, fresh opaque bearer issuance, authenticated /me,
  safe user-field response and initial unverified status.
- SMTP delivery to Mailpit, capture of the verification link, confirmation that
  its token is a URL fragment, verification success and replay rejection, then
  /me with verified status.
- Active-session listing, individual session revocation and 401 on replay.
- Device listing/revocation and 401 for related sessions.
- Logout followed by 401 on the revoked session.
- Identical forgot-password responses for an existing and missing email,
  actual captured reset email, hashed reset-token storage, successful reset,
  invalidation of pre-reset sessions, reset-token replay rejection, old-password
  failure and new-password success followed by logout.
- Six web routes returning HTTP 200 with no-referrer headers, missing/hostile
  Origin returning 403, successful cookie-proxy login with no bearer in JSON,
  HttpOnly/Secure/Strict/no-Domain cookie attributes, authenticated account GET
  through that cookie and server-side invalidation after logout.

No raw reset/verification links, password hashes or session hashes were exposed
by normal API responses. Direct native API login intentionally returns the newly
issued bearer once; browser login strips it and sets only an HttpOnly cookie.
This explicit issuance exception is required to authenticate a native client.
All normal registration/recovery/list/current-user responses were checked for
sensitive fields. HTTP health remains available and unchanged.

### Security integration coverage

The PostgreSQL suite covers every required security category, grouped into 20
account tests: registration/duplicates/normalization; hash-only passwords and
tokens; correct/wrong/unknown/disabled login; authenticated safe /me; session
expiration and logout/revocation; verification expiry/single use and resend;
generic recovery, reset expiry/single use and revocation of existing sessions;
devices, ownership isolation, safe database failures and actual HTTP rate
limiting. Additional race checks executed concurrent registration, concurrent
verification and reset consumption (exactly one winner), and a login that
finishes password verification before a reset but must not issue a session with
the stale password afterward. Expiry uses server PostgreSQL timestamps and
fixture-only updates, not sleeping through production token lifetimes.

Flow tests substitute an in-memory mailer and bypass the guard solely in their
test app so they can cover many paths without hitting shared test IP limits.
Separate unit cases test register/login/forgot/resend limits; a separate real
HTTP test app uses the unmodified guard and reaches 429. There is no application
environment switch that disables rate limiting. Production-strength hashing
parameters are used in every test; they were not reduced for speed.

### Repairs during validation and remaining limitations

An initial Argon2 test assumed a fixed parameter serialization order; actual
argon2 emits the same parameters in another order. The test now parses/sorts
parameter values. A web build initially failed because a test assigned Next.js's
read-only NODE_ENV type; cookie policy now accepts an explicit test argument
without mutating NODE_ENV. Final tests/builds passed after these repairs.
The initial Mailpit pull failed because this shell's inherited PATH omitted
Docker's credential helper; adding the installed bin directory to that command's
process PATH fixed it. No global PATH change or architecture workaround was made.

Mailpit and PostgreSQL remain local development services. The API and web
processes started for validation were stopped afterward. Live fixture accounts,
revoked session metadata, audit rows and captured mails remain only in the local
development environment; temporary passwords were never persisted in files.
The unique integration fixture schemas were removed. No existing customer rows
or Docker volumes were deleted, and .env remains ignored.

No remaining blocker for the executed Windows API/web/database flows. iOS
Keychain/networking/UI behavior still requires macOS/Xcode execution. Known
production limitations are documented in AUTHENTICATION.md and THREAT_MODEL_AUTH.md:
no durable mail outbox/provider, single-process limits and proxy-IP grouping,
email-based recovery risk, no MFA/passkeys or breach-password corpus, local
development owner role/TLS, initial non-immutable audit storage and deferred
deployment CSP/operations. The source scanner is heuristic; its clean result is
not a claim of comprehensive secret detection or production readiness.

## ACL-001B: completed live PostgreSQL validation

Executed on 2026-10-01 on this Windows machine in C:/Acloud with Node.js
v24.16.0 and npm 11.17.0. **This foundation record supersedes the
Docker/PostgreSQL blockers in the historical ACL-001A and ACL-001 records below.**
All requested live database checks were executed successfully. ACL-002 was not
started. No application logic, schema, dependencies or infrastructure
configuration changed; the source deliverable for ACL-001B is this record.

### Docker access and PostgreSQL startup

Docker Desktop is installed per-user and its backend is running. The existing
shell inherited an old PATH, so its initial `docker` commands returned
CommandNotFoundException. The executable was located at
%LOCALAPPDATA%/Programs/DockerDesktop/resources/bin/docker.exe, and that absolute
path was used for every Docker command below; no installation or global PATH
change was performed. The persisted user PATH already includes that directory.

Executed version checks returned Docker CLI **29.8.1** (build 4a63305), Docker
Compose **v5.5.1**, and engine **29.8.1**. Initial sandbox engine access failed
with permission denied on the Docker Desktop Linux engine named pipe. Approved
commands outside the sandbox then succeeded. These initial access failures
were resolved before the live checks; they are not remaining database blockers.

Docker commands used this existing configuration and root environment file:
`compose --env-file .env -f infrastructure/docker/compose.yml`.
`up -d --wait --wait-timeout 60 db` exited 0 and confirmed
`media-backup-dev-db-1` running and healthy, using `postgres:17-alpine` on
loopback port 5432. The container was already running when first inspected.
The named persistent volume is `media-backup-dev_database-data`.

### Exact executed results

| Check / command | Actual result |
| --- | --- |
| Initial PostgreSQL startup/health: Compose `up -d --wait --wait-timeout 60 db`, followed by `ps` | Exit 0; running, healthy. |
| First `npm.cmd run db:migrate` | Exit 0; `Migrations complete: 1 applied.` |
| Second `npm.cmd run db:migrate` | Exit 0; `Migrations complete: 0 applied.` |
| Live database baseline query | Assertions passed: exactly one migration, `001_foundation.sql`; stored SHA-256 equals the version-controlled SQL file; foundation metadata equals `schema_stage = foundation`. Saved migration name, checksum, original applied_at and metadata for later comparison. |
| Live advisory-lock contention | Assertions passed: held transaction-scoped advisory lock 73491001 on one PostgreSQL connection, started the actual migration runner on another, observed its ungranted advisory lock in pg_locks, then released the holder. The waiting runner completed with 0 applied. |
| Separate shared and API builds before API startup | `npm.cmd run build --workspace @backup/shared` and `npm.cmd run build --workspace @backup/api` both exited 0. |
| API startup | `node --env-file=.env apps/api/dist/main.js` started and reported listening on port 3001. The same process was kept running through both database restart scenarios. |
| Live healthy `GET /health` | Assertions passed: HTTP 200, exact JSON `{"status":"ok","checks":{"api":"up","database":"up"}}`, Cache-Control no-store. |
| Live healthy response secrecy | Passed: configured DATABASE_URL, database username/password and sensitive infrastructure field patterns absent; exact response whitelist contains only status and API/database availability. No credential values printed by validation helpers. |
| Compose `stop db` with API still running | Exit 0; PostgreSQL stopped. |
| Live outage `GET /health` | Assertions passed: HTTP 503, exact JSON `{"status":"degraded","checks":{"api":"up","database":"down"}}`, no-store and the same credential/infrastructure secrecy assertions. |
| Restart PostgreSQL: Compose `up -d --wait --wait-timeout 60 db` | Exit 0; healthy. |
| Live recovery `GET /health` | Assertions passed: HTTP 200 and exact healthy JSON; no API process restart. Database snapshot comparison passed, including original migration timestamp and foundation metadata. |
| Compose `down` without -v | Exit 0; development container/network removed. No volume removal requested. |
| Docker `volume inspect media-backup-dev_database-data --format '{{.Name}}'` after down | Exit 0; named volume still present. |
| Compose `up -d --wait --wait-timeout 60 db` after full down | Exit 0; a new container started successfully and became healthy using the existing volume. |
| Persistence comparison before rerunning migrations | Passed: migration name, checksum, original applied_at and foundation metadata exactly matched the saved pre-restart snapshot. |
| Post-recreation `npm.cmd run db:migrate` | Exit 0; `Migrations complete: 0 applied.` Subsequent snapshot comparison also passed. |
| Live health after stack recreation | Assertions passed: HTTP 200, API up, database up, exact safe response. Same API process recovered from the recreated container. |
| `npm.cmd test` | Exit 0; **11 passed, 0 failed, 0 skipped**: migration unit tests 3, shared validator 1, API 5 in 2 Jest suites, web 2. |
| `npm.cmd run build` | Exit 0; shared and API TypeScript builds passed; Next.js 16.3.8 production build passed compilation, type checking and route generation for `/`, `/_not-found` and dynamic `/status`. |
| `npm.cmd run test:integration` | Exit 0; **1 passed, 0 failed, 0 skipped**. Real PostgreSQL migration repeatability, foundation metadata and database-backed HTTP 200 health assertions passed. |
| Final database snapshot and live health after automated integration | Passed: original migration state and foundation metadata unchanged; HTTP 200 with safe healthy response. |
| `npm.cmd run security:scan` | Exit 0; **52 Git-visible files scanned, 0 unexpected findings, 4 reviewed local/test example lines**. Repeated after updating this record with the same result. |
| `git check-ignore .env .npm-cache` | Exit 0; both ignored. |
| Final Compose `ps db --format '{{.Name}} {{.State}} {{.Health}}'` | Exit 0; `media-backup-dev-db-1 running healthy`. |

The live HTTP and snapshot assertions were executed with a temporary helper in
the ignored .npm-cache directory. The helper loads the existing .env, requires
a loopback database, compares complete public health responses, checks configured
credentials are absent, and queries migration metadata directly. These assertions
are additional executed live checks, not extra cases counted in the Node test
suite. The integration suite contributed a separate passing test, giving
**12 passing automated Node tests including integration**.

The live checksum check verified persisted SHA-256 against the real migration
file; the stored checksum and migration files were never altered. Checksum
mismatch rejection and SQL-error rollback passed in the migration unit suite;
a deliberately corrupted database checksum was not injected. Advisory-lock
blocking/release was observed against real PostgreSQL, not inferred from mocks.

### Security, final state and remaining scope

No secrets, passwords, connection strings, usernames, host credentials or
sensitive infrastructure details appeared in any checked health response.
The repository scanner found only public local-development defaults/test fixtures
and Compose variable references. The scanner is heuristic, not a guarantee that
all secret formats are detected; no new npm vulnerability audit was run.

No customer data was modified or deleted. No volume deletion or database reset
was performed. Database state was compared before and after restart, recreation,
migration rerun and integration testing. PostgreSQL is left running and healthy;
the host API process started for these checks was stopped afterward. Temporary
snapshots/helpers are ignored and contain no credential values in their output.
No commits or remote pushes were made.

**No remaining blocker for the requested Windows live database validation.**
The Swift/XCTest suite and SwiftUI build were not executed on Windows; their
previous macOS validation limitation remains outside ACL-001B's database scope.
The optional API Docker image and GitHub Actions workflow were not executed in
this task; host API and the existing PostgreSQL Compose service were validated.
No authentication, PhotoKit, uploads, payments, object storage, subscription
logic or production infrastructure was added.

## ACL-001A: Windows integration validation and repair

Re-executed on 2026-10-01 in C:/Acloud, Windows, Node.js v24.16.0,
npm 11.17.0. This section is the historical ACL-001A result; the original
ACL-001 record is retained below as historical evidence. ACL-002 was not started.
No architecture, application logic, schema or infrastructure configuration was
changed for this task. No dependencies or system software were installed.

### Docker availability evidence

- `Get-Command docker` and `Get-Command docker-compose`: neither command found.
- `docker --version`, `docker compose version` and `docker info`: PowerShell
  CommandNotFoundException; no CLI version, Compose version or engine status
  could be obtained. The combined diagnostic command exited 1.
- All three checked all-users installation files are absent:
  C:/Program Files/Docker/Docker/Docker Desktop.exe,
  C:/Program Files/Docker/Docker/resources/bin/docker.exe,
  C:/Program Files/Docker/Docker/resources/cli-plugins/docker-compose.exe.
- Per-user Docker Desktop executable absent at
  %LOCALAPPDATA%/Programs/DockerDesktop/Docker Desktop.exe.
- No Docker entries found in HKCU/HKLM uninstall registrations, including the
  WOW6432Node registry location.
- No Docker Desktop or com.docker.backend processes found; no
  com.docker.service registered. Absence of that service alone would not prove
  Docker absent, since per-user WSL installations do not require it.
- The `wsl` command exists. A functioning/current WSL 2 backend, its version,
  virtualization readiness and OS compatibility were **not established**.
- Root .env exists. A credential-suppressing configuration assertion confirmed
  DATABASE_URL targets loopback before database commands were attempted.

Conclusion: Docker Desktop, its CLI and Compose are not available on this
machine in PATH or standard registered installation locations. There is no
detected running Docker engine. This is a missing Docker installation/setup
blocker, not merely a PostgreSQL health-check failure.

### Commands actually executed and results

| Check | Exact result |
| --- | --- |
| `npm.cmd run services:up` | Exit 1; `'docker' is not recognized as an internal or external command, operable program or batch file.` PostgreSQL was not started. |
| `npm.cmd run db:migrate`, first attempt | Exit 1; `Migration failed. Check database availability/configuration and migration history. Details suppressed to protect credentials.` |
| `npm.cmd run db:migrate`, second attempt | Exit 1; same safe diagnostic. Two failures do not prove migration idempotency. |
| `npm.cmd run test:integration` | Exit 1; 1 failed, 0 passed, 0 skipped; `connect ECONNREFUSED 127.0.0.1:5432`. Migration application and database-backed health success were not validated. |
| Built API startup | `node --env-file=.env apps/api/dist/main.js` started successfully and reported listening on port 3001. |
| Live `GET /health` | Assertions passed: HTTP 503; exact JSON `{"status":"degraded","checks":{"api":"up","database":"down"}}`; `Cache-Control: no-store`. |
| Live response secrecy | Assertions passed against the configured connection string, database username and password, plus sensitive-field patterns. Exact response whitelist contains no host, credentials, secrets or infrastructure error details. Credential values were not printed by this check. |
| Stop PostgreSQL, check degraded, restart and recover | **Not executed**: no PostgreSQL container or Docker engine exists. Observing the initially unavailable database does not establish outage/recovery behavior. |
| Compose down/up without deleting volumes and verify persisted state | **Not executed**: no initialized PostgreSQL volume or applied migration is available for inspection. |
| Live migration checksum and advisory-lock verification | **Not executed** against PostgreSQL. Mock checks passed as recorded below; actual PostgreSQL locking/checksum behavior remains unverified. |
| `npm.cmd run build --workspace @backup/shared` | Exit 0; TypeScript compilation passed. Also rebuilt successfully in the aggregate build. |
| `npm.cmd test` | Exit 0; **11 passed, 0 failed**: migration mocks 3, shared validator 1, API 5 in 2 Jest suites, web 2. |
| Migration mock assertions in `npm.cmd test` | Passed: lock query ordering, atomic checksum tracking/commit, repeat-run skipping, checksum mismatch rejection, SQL-error rollback and connection cleanup. These are not real database integration results. |
| `npm.cmd run build` | Exit 0; shared TypeScript, API TypeScript and Next.js 16.3.8 production build passed; web type checking and route generation completed for `/`, `/_not-found` and dynamic `/status`. |
| `npm.cmd run security:scan` | Exit 0; **52 Git-visible files scanned, 0 unexpected findings, 4 reviewed local/test example lines**. |
| Broad `rg` credential search | Reviewed password/secret/credential/key/token/database URL references. Only deliberate local/test defaults, configuration placeholders and documentation references found. |
| `git check-ignore .env .npm-cache` | Exit 0; both ignored. Temporary live-health assertion script resides in the ignored npm cache and is not a source deliverable. |

The test/build/scan commands ran with approved sandbox escalation because their
tools spawn child processes. The API used for the live check was stopped after
validation. No containers or volumes were created or deleted. No production
credentials or customer data were used. No commits or remote pushes were made.
The security scan remains heuristic; this rerun did not perform a new dependency
vulnerability audit. The earlier installation audit below is historical.

### Minimum Windows setup to unblock integration

These are instructions, **not steps executed during ACL-001A**.

1. Check that Windows and hardware meet the current
   [Docker Desktop Windows requirements](https://docs.docker.com/desktop/setup/install/windows-install/).
   Enable BIOS/UEFI hardware virtualization if disabled. Run `wsl --version`;
   Docker's WSL backend requires WSL 2.1.5 or later. If needed, open Administrator
   PowerShell, run `wsl --install` for missing WSL or `wsl --update` for an older
   installation, and reboot if requested.
2. Download and install Docker Desktop for Windows from that official page,
   selecting the WSL 2 backend and Linux containers. Per-user installation is
   sufficient for this project. Docker Desktop includes
   [Docker Compose](https://docs.docker.com/compose/install/); no separate
   PostgreSQL installation or Compose standalone download is needed.
3. Launch Docker Desktop, complete its first-run setup, and wait until the engine
   is running. Open a new PowerShell window so PATH changes are visible. Confirm:

```powershell
docker --version
docker compose version
docker info
```

Then run from the existing workspace without overwriting its .env:

```powershell
Set-Location C:\Acloud
docker compose --env-file .env -f infrastructure/docker/compose.yml up -d --wait --wait-timeout 60 db
npm.cmd run db:migrate
npm.cmd run db:migrate
npm.cmd run test:integration
# Start in a separate terminal:
npm.cmd run dev:api
# After the API starts:
Invoke-RestMethod http://127.0.0.1:3001/health
```

Both migration runs must succeed; a repeat run after all migrations are applied
must report `0 applied`. The live endpoint must return HTTP 200 with status ok,
api up and database up. These expected outcomes have **not** occurred on this
machine yet. Outage/recovery, persisted state after Compose down/up, checksum
tampering rejection and advisory-lock contention still require a Docker-enabled
validation run. Do not use `down -v` or delete volumes to make the checks pass.

Remaining blocker: install/configure/start Docker Desktop and its Linux engine.
Real PostgreSQL migrations and integration cannot be accepted as passed until
the blocked checks are actually executed successfully. No ACL-002 functionality
was added.

## Original ACL-001 validation record

Executed on 2026-10-01 on Windows, Node.js v24.16.0, npm 11.17.0.
Resolved framework versions include Next.js 16.3.8, with exact dependency
versions recorded in package-lock.json. No remote repository was pushed.

| Check | Actual result |
| --- | --- |
| npm install | Exit 0; 460 packages added, 464 audited; 0 vulnerabilities reported |
| npm test (final run) | Exit 0; 11 tests passed, 0 failed: migration 3, shared 1, API 5 in 2 suites, web 2 |
| npm run build | Exit 0; shared and API TypeScript compilation passed; Next.js production build compiled, type-checked and generated routes /, /_not-found and dynamic /status |
| npm run test:integration | Exit 1; 1 test failed, 0 passed; connect ECONNREFUSED 127.0.0.1:5432 |
| npm run db:migrate | Exit 1; database unavailable; safe generic diagnostic, no credential output |
| Live built API GET /health | HTTP 503 with exact {status: degraded, checks: {api: up, database: down}} payload; assertion passed |
| Live built web GET / | HTTP 200 and Acloud display text; assertion passed |
| Live built web GET /status | HTTP 200 and Unavailable display text against running API with unavailable database; assertion passed |
| Credential scan | Exit 0; 52 Git-visible files scanned, 0 unexpected findings, 4 reviewed local/test example lines |
| Broad rg credential search | Reviewed password/secret/key/token/database-URL references; only local/test defaults, variable references and safety documentation found |
| Ignore verification | .env, .npm-cache, node_modules, API dist and web .next confirmed ignored |
| Git | Initialized locally; no commits or remote pushes |
| Docker Compose / Dockerfile | Not executed: Docker is not installed on this machine |
| Swift XCTest / SwiftUI build | Not executed: Swift and Xcode are unavailable on this Windows machine |
| GitHub Actions | Workflow created, not executed |

Earlier attempts at Node test/build processes failed with sandbox `spawn EPERM`.
Approved reruns outside the sandbox passed. An initial integration attempt also
failed before execution because .env did not exist; after copying the public
development template, the final integration result was the connection refusal
recorded above. An initial ad hoc smoke command had a shell quoting error; the
subsequent file-based assertions passed. These earlier failures are not counted
as successful checks.

A build attempt passing Node's --env-file-if-exists directly to Next.js failed
because Next forwarded that option into NODE_OPTIONS for its worker. The web
configuration now loads the root .env through Node's API instead, avoiding that
worker flag propagation.

The real database-backed success path, migration execution against PostgreSQL,
Docker startup and iOS build/tests remain unverified. Mock tests demonstrate
logic, not successful live PostgreSQL connectivity. Run the documented commands
on a Docker-enabled host and Mac before treating those paths as validated.

Security review found deliberate public local credentials in .env.example,
test-only fake credentials in the database service tests and variable-interpolated
Compose credentials. The CI service also uses the same public local development
password. No production API keys, private keys or unexpected credential literals
were identified. .env is ignored. There is no committed Git history to audit.
The scanner is heuristic, excludes lockfile integrity hashes and its own pattern
source, and does not guarantee detection of all possible secret formats.

The npm install reported a deprecated transitive glob package and install-script
policy notices for esbuild, @parcel/watcher and unrs-resolver. Actual tests and
builds succeeded; npm's vulnerability audit reported zero at installation time.
Keep auditing the locked dependencies as development continues.

Recommended manual review: AGENTS.md; architecture, security and lifecycle docs;
SQL migration and migration runner; health controller and database service;
Compose port/volume/credential configuration; iOS project.yml, ATS configuration,
bundle ID/signing and networking code; CI workflow. .env.example defaults are
strictly for local development, never deployment.
