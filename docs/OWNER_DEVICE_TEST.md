# Private hosted device acceptance mode

This mode permits an owner-authorized disposable-fixture test on a hosted staging stack without asserting beta release acceptance. Default is off. No migration and no beta acceptance writes are introduced. Existing user/device/session authorization, quota reservation, server checksum/version verification and storage binding remain mandatory.

## Limits

- Exactly one verified, active, non-abuse-reviewed account and one registered, non-revoked device. Browser sessions and other accounts/devices cannot reserve or restore test assets.
- Fixed UTC start/end, at most 24 hours; preparation helper defaults to two hours. Expiration stops new authorizations. Previously issued signed URLs retain their bounded lifetime; issuing TTL is capped at the window end.
- Two upload sessions per account since the start, at most 32 MiB each / 64 MiB total, multipart only. Failed/cancelled attempts count; retry the same idempotency key. Ordinary account quota can be lower and is still enforced.
- Only assets created within this window on that device qualify for test operations. Restore still requires PROTECTED evidence, matching checksum/size, storage binding and exact version. The Debug UI shows only the returned test photo/video IDs, one restore at a time. This is not the signed beta release path.
- Global beta, public registration, payments, support tools and deletion/retention execution flags remain false. RESTORE_ENABLED also stays false; this mode has its own narrow restore branch.
- Upload/multipart/download/restore pause switches must exist and be unblocked for the relevant operation. Opening these switches does not enable normal beta access. Do not change unrelated worker, payment, privacy or deletion switches.

## Deployment sequence

1. Build/test and review the scoped backend change. Deploy with OWNER_DEVICE_TEST_ENABLED absent or false. Keep the worker's test mode off; client completion uses the existing verified upload path. Do not push unrelated local native/source work.
2. Confirm the deployed commit and health, and check actual Railway API configuration against the private local configuration. Resolve the test account's database UUID and the iPad's current device UUID using a read-only query. Do not guess the device from its name when multiple devices exist. User has already confirmed hosted sign-in for schoolpadi2024@gmail.com.
3. With the compiled API available, run `node --env-file=<private-api-env> scripts/prepare-owner-device-test.mjs ACCOUNT_UUID DEVICE_UUID NEW_PRIVATE_OUTPUT_FILE`. The helper reads configuration, validates it and writes only six owner-test settings; it does not read/write the database or deploy. Keep the output private. Review timestamps and resource hash before importing into the API service only. Do not copy the entire private API environment into the frontend.
4. Review current values of the four relevant beta_switches (uploads, multipart, downloads, restore), record originals, and explicitly apply their bounded unpause for the scheduled test. No beta acceptance rows should be modified. Keep all destructive switches blocked.
5. Build/install the updated Debug iPad app with the already verified hosted API/storage origins. Confirm account sign-in. Use one disposable ordinary image and one short unedited video smaller than 32 MiB each. No original deletion. Verify PROTECTED, matching downloaded bytes and Photos restore/playback. The optional generated 20 MiB upload consumes one of the two slots, so do not run it if both photo/video slots are needed.
6. Record outcomes and exact deployed build/bucket. Set OWNER_DEVICE_TEST_ENABLED=false while retaining the owner binding values, and restore previously recorded pause values. Existing signed links can live only until their issued expiry. No generated-object deletion is automated by this feature; clean up only with separately scoped exact-version authorization if desired.

Do not move the start time or clear bindings casually to recover a failed test: doing so changes which stored assets qualify and resets the bounded accounting window. Review existing reservations first. The preparer intentionally refuses to overwrite a settings file.

## Validation

API TypeScript build; dedicated isolated-local-PostgreSQL tests in apps/api/test/owner-device-test.test.mjs; existing beta/admission/local restore regression suites; HealthClient Swift tests; full iOS Debug compilation. Provider fixture tests do not prove live B2 throughput or physical Photos acceptance. No live setting change is implied by passing these tests.
