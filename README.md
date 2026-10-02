# Acloud — ACL-004 verified upload foundation

Acloud is a privacy-focused cloud photo and video backup platform, initially
targeting iPhone users in Nigeria. This repository contains **only the project
and authentication foundation, local iOS metadata discovery and generated-file
verified uploads**, not a customer-media backup service. Customer-data protection and
prevention of data loss take priority over feature delivery.

Intended architecture: iOS and web -> NestJS API -> PostgreSQL, private object
storage and background workers. The website will handle future storage purchases;
the iOS app contains no payments. Internal package names and database tables use
neutral media-backup terminology so branding can change independently.

```text
apps/
  api/                    NestJS health/auth API, security tests and SQL migrations
    src/uploads/          Scoped S3 authorization, quota and server verification
  web/                    Next.js status, account forms and cookie proxy
  ios/                    SwiftUI discovery/status/auth and XcodeGen project source
    Packages/HealthClient/  Networking, Keychain token storage and XCTest suite
    Packages/PhotoDiscovery/ Metadata scanner, protected SQLite, PhotoKit adapter and mock XCTest suite
    Packages/UploadFoundation/ Generated-file queue, transport, state and native tests
packages/shared/          TypeScript health contract and runtime validator
infrastructure/docker/    Local Compose and API Dockerfile
docs/                     Architecture, security, lifecycle and validation
scripts/                  Migration runner, credential scan and live auth validator
AGENTS.md                 Repository-wide engineering safety rules
.env.example              Local-only configuration template
```

PhotoKit discovery remains local; no discovered media/metadata is automatically
sent to the server. Sizes remain unknown in the default iOS 17 build; see
[PhotoKit architecture](docs/PHOTO_LIBRARY_DISCOVERY.md),
[pending native validation](docs/IOS_VALIDATION_PLAN.md) and
[exact executed results](docs/VALIDATION.md).
ACL-004 adds an explicit **≤5 MiB generated-file** direct upload path with
server-side size/SHA-256 verification and version-pinned private download.
UPLOADED does not mean PROTECTED. See [upload lifecycle](docs/UPLOAD_LIFECYCLE.md),
[security/setup](docs/UPLOAD_SECURITY.md) and [review tree](docs/ACL004_TREE.md).
Physical iPhone PhotoKit upload integration remains **UNVALIDATED**; customer-media
beta requires that gate. ACL-005 has not begun.

## Prerequisites

- Node.js 24 LTS and npm 11; dependencies are locked in package-lock.json.
- Docker Desktop with Compose v2 for local PostgreSQL (or PostgreSQL 17 locally).
- Git.
- For iOS: macOS, Xcode supporting iOS 17+, and XcodeGen. Windows can work on
  API/web, but cannot compile SwiftUI or run the simulator.

## Local setup

From the repository root (Bash/macOS/Linux):

```sh
cp .env.example .env
npm ci
npm run build --workspace @backup/shared
npm run storage:configure
npm run services:up
npm run db:migrate
```

On Windows PowerShell:

```powershell
Copy-Item .env.example .env
npm.cmd ci
npm.cmd run build --workspace @backup/shared
npm.cmd run storage:configure
npm.cmd run services:up
npm.cmd run db:migrate
```

Storage setup generates separate random local root/application credentials in
ignored .env. services:up also builds source-pinned development MinIO, creates a
private versioned bucket and starts a persistent loopback-only storage API; first
build can take several minutes. Do not delete volumes for routine shutdown.

Use `npm.cmd` for all subsequent npm commands on Windows if PowerShell blocks
npm.ps1. Wait for PostgreSQL to become healthy (`docker compose --env-file .env
-f infrastructure/docker/compose.yml ps`) before running migrations. Copying
.env is a first-time step; do not overwrite an existing developer configuration.

Run in two separate terminals:

```sh
npm run dev:api
npm run dev:web
```

Visit http://localhost:3000 and http://localhost:3000/status.
Account test pages: /register, /login, /account, /forgot-password,
/reset-password and /verify-email. Open http://localhost:8025 for the local
Mailpit mailbox. Registration/verification and reset emails stay in this sink;
no external email is sent. Links carry tokens in a fragment and must be opened
in the browser; tokens are never returned by registration/recovery endpoints.

Existing ACL-001 checkouts should add DEV_MAIL_ENABLED, DEV_SMTP_HOST,
WEB_BASE_URL and WEB_ORIGIN from .env.example to their ignored .env, without
overwriting credentials. services:up now starts both PostgreSQL and Mailpit.
On Windows after installing Docker, open a new terminal; an already-running
Codex shell may still have the old PATH. The installed Docker directory must be
on that shell's PATH so its credential helper can also be found.
GET http://localhost:3001/health returns:

```json
{"status":"ok","checks":{"api":"up","database":"up"}}
```

If PostgreSQL is unreachable, it returns HTTP 503 and `status: "degraded"` with
`database: "down"`. The web and iOS report Unavailable. There are no credentials,
server addresses, stack traces or database exception messages in the response.
This checks reachability, not backup protection or migration currency.

## Environment variables

Root .env is loaded explicitly by API scripts and the Next.js configuration; API_BASE_URL is
server-only, not a NEXT_PUBLIC variable.

| Variable | Purpose / local default |
| --- | --- |
| POSTGRES_USER | Compose local owner: backup_dev |
| POSTGRES_PASSWORD | Deliberately public development default; never use in production |
| POSTGRES_DB | Local database: backup_dev |
| DATABASE_URL | Host API/migration connection to 127.0.0.1:5432 |
| API_PORT | Host API port: 3001 |
| API_BASE_URL | Next.js server connection: http://127.0.0.1:3001 |
| PRODUCT_NAME | Website display branding: Acloud |
| DEV_MAIL_ENABLED | Explicit dev-only SMTP gate: true |
| DEV_SMTP_HOST | Local sink: 127.0.0.1; Compose API uses internal mail host |
| WEB_BASE_URL | Verification/reset link origin: http://localhost:3000 |
| WEB_ORIGIN | Exact allowed browser mutation Origin: http://localhost:3000 |

Keep DATABASE_URL and Compose credentials consistent if you change them. URL
credentials must be percent-encoded; use URL-safe local passwords for the Compose
API profile's interpolated URL. Changing .env does not change the password in
an existing initialized PostgreSQL volume; update the database role deliberately.
iOS branding and API URL are set separately in apps/ios/project.yml. If changing
API_PORT, update API_BASE_URL and the iOS URL. The Docker profile uses fixed 3001.

## Migrations and services

```sh
npm run db:migrate          # Forward-only, transactional, repeatable migrations
npm run services:logs       # Follow development service logs
npm run services:down       # Stop containers; preserve the database volume
npm run services:up         # Start PostgreSQL and local Mailpit
```

Optional containerized API (stop the host API first to avoid a port conflict):

```sh
npm run services:api
npm run dev:web
```

The API container waits for database health and applies migrations before it
starts. Ports bind to loopback; the database uses a persistent named volume.
Do not use `docker compose down -v`: it destroys the local database. No automatic
reset or down-migration command is supplied. Do not edit applied SQL files; add
a new migration. Destructive migrations require a documented recovery strategy.

## Tests and builds

```sh
npm run build --workspace @backup/shared
npm test                    # Shared validator, API Jest/Supertest, web client tests
npm run build               # Shared TypeScript, API TypeScript and Next.js build
npm run test:integration     # Requires real PostgreSQL and .env; runs migrations
npm run test:auth:live       # Running API + built web + Mailpit required; local fixtures
npm run security:scan       # Heuristic scan of Git-visible files
```

The migration unit suite checks locking, checksum enforcement, repeatability
and rollback/connection cleanup using a mock client. The HTTP suite uses a
substituted database provider to verify 200/503 behavior.
Pool tests cover successful/failed queries, shutdown and error containment.
The separate integration suite uses real PostgreSQL, checks migration repeatability
and metadata, and calls /health with a real database provider. It deliberately
fails, rather than silently skipping, if PostgreSQL is unavailable. It targets
the configured development database. Account tests create an isolated random
fixture schema and drop only that schema afterward; they never delete real user
rows. Never point tests at
production. Build shared first after a clean install; workspace consumers use its
compiled package. See docs/VALIDATION.md for checks actually executed here.
GitHub Actions configuration runs Node checks with a PostgreSQL service and
Swift networking tests plus a simulator build on macOS. It has not been run
by creating the files locally; no repository has been pushed.

The account integration suite covers registration, Argon2id, sessions,
verification/reset token hashing and expiry, concurrent single use, reset-wide
revocation, device/tenant isolation and real HTTP rate guards. For real SMTP and
browser-cookie validation, keep the API running and start a built web server in
another terminal (`npm run build`, then `npm run start --workspace @backup/web`).
Run `npm run test:auth:live`. The script creates random .invalid local accounts,
reads captured mail from Mailpit, verifies live API/browser behavior and leaves
fixture sessions revoked. It does not print passwords, credentials or links.
These fixture accounts/mail remain in development; do not use customer data.

## iOS setup

See [apps/ios/README.md](apps/ios/README.md). On macOS:

```sh
cd apps/ios
xcodegen generate
open BackupClient.xcodeproj
# Choose an iPhone simulator and Run.
cd Packages/HealthClient
swift test
```

The generated project is ignored; project.yml is the reproducible source of
truth. This avoids machine-specific signing/project files. The app displays the
working brand, Development Build, API status and basic Sign In/Create Account/
Signed In screens. Session tokens use Keychain, never UserDefaults. It requests
no photo permissions and implements no uploads or payments. New networking and
Keychain tests require macOS/Xcode execution before iOS validation is complete.

## Security and limitations

Never commit .env, production credentials, private keys or customer data. The
template's local credentials and test fixtures are public examples, not secrets.
The scan is a heuristic and does not establish that arbitrary secrets or Git
history are clean. Review changes and use a dedicated scanner before publishing.

This scaffold has server-side authentication but no production-ready deployment,
external email provider, MFA or passkeys. It has no Paystack, Backblaze B2, PhotoKit,
uploads, object storage, subscription schema, workers or production deployment.
No privacy/encryption/backup guarantees are implemented. Local PostgreSQL uses
a convenience owner and persistent volume, not least-privilege production roles
or a recovery system. A future media asset is PROTECTED only after independent
server integrity verification; UPLOADED never implies PROTECTED. Device originals
must never be automatically deleted.

Read [AGENTS.md](AGENTS.md), [architecture](docs/ARCHITECTURE.md),
[security principles](docs/SECURITY_PRINCIPLES.md) and
[data lifecycle](docs/DATA_LIFECYCLE.md) before extending this foundation.
Read [authentication](docs/AUTHENTICATION.md) and the
[account threat model](docs/THREAT_MODEL_AUTH.md) for contracts, security choices
and limitations. ACL-003 has not been started. No remote push is part of this task.
