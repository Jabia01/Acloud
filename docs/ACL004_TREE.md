# ACL-004 manual review tree

```text
AGENTS.md                                       ACL-004 safety/scope; no ACL-005
README.md                                       Local upload setup and validation boundaries
.env.example                                    Empty storage credential placeholders, limits/TTLs
.github/workflows/ci.yml                         Pending S3 integration + native upload test jobs
apps/api/
  migrations/003_verified_uploads.sql            Additive quota/assets/sessions/verifications/audit
  src/uploads/
    input.ts                                    Strict bounded metadata/configuration
    storage.ts                                  Abstract provider + S3 signing/versioned verification
    upload.service.ts                           Transactional quota/leases/idempotency/lifecycle
    upload.controller.ts                        Authenticated safe API routes
    upload.module.ts                            Provider injection
  src/{app.module.ts,auth/auth.module.ts}        Module wiring and exported auth guard
  test/{upload.spec.ts,upload.integration.ts}    Signed-boundary units + real SQL/S3 failure suite
  test/auth.integration.ts                      Updated fresh-schema migration count
apps/ios/
  project.yml                                   UploadFoundation package dependency
  Packages/UploadFoundation/
    Package.swift                               Neutral package; existing HealthClient dependency
    Sources/UploadFoundation/
      UploadModels.swift                        Generated payloads, phases and protocols
      HTTPUploadClients.swift                   Keychain-backed API + direct no-bearer transport
      FileUploadStateStore.swift                Bounded protected atomic state, no signed URLs
      UploadCoordinator.swift                   Explicit queue/cancel/retry/server authority
    Tests/UploadFoundationTests/UploadTests.swift Authored generated/mock native cases (unexecuted)
packages/shared/{src/index.ts,test/upload.test.ts} Safe asset contract and protection predicate
infrastructure/docker/
  compose.yml                                   Loopback private versioned persistent S3 service
  storage.Dockerfile                            Pinned security-fixed upstream source build
  storage-init.sh                               Private bucket/versioning/scoped application user
scripts/
  setup-storage-env.mjs                          Ignored local random credentials; preserve config
  validate-upload-live.mjs                       Running API generated roundtrip + optional restart
  list-abandoned-uploads.mjs                     Read-only aggregate inventory; no deletion
  test/migrate.test.mjs                          Migration fixture discovery instead of stale list
docs/{UPLOAD_SECURITY.md,UPLOAD_LIFECYCLE.md,VALIDATION.md,IOS_VALIDATION_PLAN.md}
```

Priority review: migration constraints, user-first quota/reservation locking,
verification finalization/lease/auth checks, signed headers/expiry/version pinning,
cancellation's retained reservation, MinIO init policy, native cancellation/lost
PUT response paths and all recorded validation limitations. PhotoKit discovery
code remains local and unchanged; no payment/production/automatic deletion work.
