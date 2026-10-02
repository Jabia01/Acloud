# ACL-004 upload security and local storage setup

This foundation is validated only with generated data. It is not a production
deployment, large-media backup service or physical-iPhone upload validation.
See [lifecycle/API contract](UPLOAD_LIFECYCLE.md) and [executed checks](VALIDATION.md).

## Direct upload and provider abstraction

ObjectStorageProvider exposes scoped upload/download authorization, object
metadata, verification and version-specific deletion. S3ObjectStorageProvider
uses official AWS SDK v3; business logic depends on the abstract provider.
API accepts JSON only; the client sends payload directly to private S3-compatible
storage. Server GET streams a capped object solely to verify it, never forwards
that body to a client or keeps a disk copy. This documented small-file server
read is necessary for the provider-independent SHA-256 policy; large payloads
remain out of scope. The API never proxies the upload body.

Signed PUT binds exact random key, Content-Length, application/octet-stream,
expected SHA-256 and If-None-Match:*. It expires within 300 seconds and the
session's original deadline. Altered key/headers/method are rejected at storage.
[S3 conditional writes](https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes.html)
prevent replacement at an existing key. The client sends no API bearer to S3;
native transport disables cookies/credential storage/redirects and checks an
explicit trusted storage origin. HTTPS is mandatory outside explicit local dev.

Signed URLs are temporary bearer capabilities, not permanent object URLs.
They necessarily include endpoint, bucket/key and the non-secret signing access
identifier. Neither root/application secret key nor master password is returned.
Safe asset/status responses omit bucket, key, version and provider metadata.
Never log/persist signed URLs or put them in analytics/referrers. API replies are
no-store/no-referrer; download is attachment/download.bin with octet-stream.

## Integrity, replay and immutable reads

Expected size and lowercase SHA-256 are mandatory. Native generated files are
hashed incrementally; server verifies existence and exact bytes against metadata
captured at creation. Provider success booleans are independently checked against
the expected size/digest and a non-null immutable version. Never rely on ETag as
MD5 or as SHA-256: [S3 integrity checks](https://docs.aws.amazon.com/AmazonS3/latest/userguide/checking-object-integrity.html)
and multipart semantics vary. The PUT digest also lets local S3 reject corrupt
bytes early; server verification still streams/hashes the exact selected version.

Bucket versioning must be Enabled. HEAD selects a version, GET hashes that version,
and the successful version ID is persisted atomically with protection. Future
downloads always pin it. This avoids verifying one object and serving a later
overwrite; a real test overwrites a generated key with privileged server test
credentials and confirms the verified version still downloads intact. A provider
without this immutable-version contract fails closed until a suitably immutable
provider implementation is supplied. Root/provider compromise can still destroy
versions; ACL-004 does not claim protection against compromised administrators.

Create idempotency is user-scoped and fingerprint-bound. Completion owns one
durable verifier lease, with unique attempt ID and immutable successful audit.
Lease expiry permits crash retry; finalization rechecks lease/session state and
authentication. Successful duplicates are no-ops. A lost PUT response is handled
by probing server completion before replay, since create-only replay returns 412.

## Tenant isolation and quotas

All create/start/complete/cancel/status/asset/download routes use session auth.
Device ownership and revocation are checked. Queries include owner ID; unsigned
object URLs are anonymous-denied. Keys use objects/random-prefix/random-UUID,
never user email, device identifier, filename or PhotoKit localIdentifier.
Cross-tenant tests cover inspect/start/complete/cancel/asset/download. Revoked
sessions cannot mutate uploads. Signed capabilities already issued cannot be
instantly revoked by account logout; short TTL is the bounded residual capability.
Revocation prevents subsequent API completion/download authorization.

FREE_DEV entitlement is stored per user, initialized from configurable
FREE_DEV_QUOTA_BYTES (20 MiB default) on first upload mutation. Existing rows do
not silently change when configuration changes. There is no subscription or
client-trusted usage input. A user row and entitlement row lock serialize
protected_bytes + reserved_bytes + requested_bytes ≤ quota_bytes, with a DB
constraint as a second guard. Verification moves reservation to protected usage
once in the same transaction; no unreserved protection is allowed.

Cancellation does not revoke an already signed PUT. Its reservation therefore
remains held until original expiry. Expired reservations are reconciled on the
next authenticated upload mutation; active verifier leases defer reclamation
until safe. This tracks protected bytes and outstanding authorization reservations,
not all provider billing usage/noncurrent versions/orphans. There is no claim that
these logical quota counters exactly equal physical storage invoices.

## Filenames, oversize and resource bounds

The API rejects original_filename, object key, status and unknown creation fields.
No filename from a client becomes a path, storage key or download header. Metadata
size must be a positive safe integer ≤5 MiB; digest is 64 lowercase hex. Signed
Content-Length prevents an authorized key from accepting arbitrary larger bodies;
server HEAD/stream byte limits reject mismatched objects even if a privileged
writer bypasses signing. Verification uses incremental SHA-256 and deadlines
without buffering whole objects. Native queue is capped at 32 test payloads;
no full-library traversal or thumbnail/media loading is added to discovery.

This is not production abuse control. Distributed verification capacity,
durable workers, storage billing reconciliation, upload-rate controls, malware
policy and multipart transfer require later design before customer-media beta.
There is no background production scheduler or paid entitlement enforcement.

## Abandoned uploads and cleanup

Expired/non-protected sessions can be identified with `npm run uploads:abandoned`;
it prints aggregate counts only and performs no deletions. Cancelled or failed
objects/versions can remain after signing expires. Retaining them avoids accidental
customer-data loss but requires a future audited retention/cleanup policy before
production; do not infer deletion consent from local Photos removal.

The provider deleteObject method is version-specific but no customer deletion
endpoint/automatic cleanup runs. Real integration tests explicitly remove only
their own recorded generated object versions and drop their random test schema;
they never list/delete arbitrary bucket contents, application assets or volumes.
The live client deliberately retains its synthetic protected object/account and
revokes its login session for inspectable persistence evidence. Volume removal
is never part of routine startup/shutdown. Any eventual destructive customer-data
operation needs explicit authorization and an audit record.

## Local MinIO setup (development only)

Upstream [MinIO security-fixed release](https://github.com/minio/minio/releases/tag/RELEASE.2025-10-15T17-29-55Z)
is source-distributed. storage.Dockerfile builds that pinned server tag and pinned
mc tag from Go modules, rather than choosing an older pre-fix server image. Go's
module verification applies; this is not a production supply-chain/container
audit. Upstream repository is archived; a maintained production provider choice
requires separate approval and review. No production B2/S3 account is required.

From the repository root after existing .env/npm setup:

```powershell
npm.cmd run storage:configure
npm.cmd run services:up
npm.cmd run db:migrate
npm.cmd run test:uploads
```

The configuration helper generates separate root and application secrets directly
in ignored .env and preserves nonempty existing values. .env.example leaves keys
empty. Never print `docker compose config`/credential-bearing mc commands into
logs or commit .env. If Docker was installed after opening this shell, open a
new shell or prepend its resources/bin directory to PATH for its credential helper.
First source build can take several minutes. Docker Desktop/Compose is required.

Storage API binds only 127.0.0.1:9000, no published/admin console and MINIO_BROWSER
is off. /minio/health/ready is the healthcheck. Named object-data volume persists.
Initialization disables anonymous access, enables versioning and creates a
separate application user with only versioning inspection and object-prefix
read/write/version-specific delete permissions. API gets application credentials;
root credentials are confined to storage/initialization. Do not use these dev
credentials elsewhere. Single-server local volume is not disaster recovery.

Run built API/web in separate terminals as in README, then:

```powershell
npm.cmd run test:uploads:live
# Optional: restart local storage and check generated object/version persistence.
npm.cmd run test:uploads:live -- --restart-storage
npm.cmd run test:auth:live
npm.cmd run uploads:abandoned
```

The host defaults use loopback S3_ENDPOINT. Optional API-in-Compose signs the
host-facing S3_PUBLIC_ENDPOINT separately from internal http://storage:9000.
SDK region/bucket and entitlement/limits/TTLs are server environment settings.
No storage setting is compiled into iOS; native transport receives a temporary
authorization and uses an explicitly configured trusted dev origin. A physical
iPhone cannot reach its Mac's storage via 127.0.0.1; real-device connectivity/TLS
and PhotoKit original integration remain pending, not a production workaround.
