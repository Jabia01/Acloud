# Staging database backup policy and automation

Status: prepared and locally tested; GitHub environment, dedicated source role, push, first cloud job and inbox verification must be completed before calling scheduling active.

## Policy

- Daily encrypted consistent application-schema snapshot at 08:17 UTC (03:17 Chicago daylight time / 02:17 standard time). Manually run daily before schema/data migrations.
- Every encrypted archive and manifest uploaded to the dedicated private B2 bucket, exact stored versions downloaded and SHA-256 checked; manifest authenticated before acceptance.
- Restore first job, on first UTC day of month, or when no recorded successful restore exists within 30 days. New network-none PostgreSQL target, no ports, exact table names/counts/canonical content hashes. No hosted cutover; local owner/ACL application omitted.
- Prune only exact version IDs in database/<timestamp>/{application.pgdump.enc,manifest.json.enc,success.json} that B2 says were uploaded more than 30 days ago. Run only after current verified backup's completion marker is remotely readable. Never delete media, keys, arbitrary paths or current run. Age is server upload time; failures may extend retention until a new verified backup exists. No independent B2 lifecycle deletion configured.
- Hourly at minute 37, check latest verified snapshot; fail/alert if absent or older than 26 hours, or restore evidence older than 31 days. Check when scheduler executes, not a guaranteed detection SLA. GitHub schedules can be delayed/dropped, so a separate platform uptime/dead-man monitor remains desirable.
- Failure and overdue notices via Resend to owner-selected Privacy247.acloud@useacloud.com. Same mode/code/day uses an idempotency key to limit duplicates. Provider acceptance is not proof of inbox receipt. Also enable owner GitHub Actions failure notifications for failures before runner notification code starts.
- Runner never has a write-capable source role. Dedicated backup_beta_backup login has SELECT on private application schema and no ownership/create/write privileges. It still reads sensitive application records; protect credentials/workflow writers.
- All backups encrypted with owner's separately retained 256-bit key. Key must be supplied to the trusted runner for encryption/monthly decryption. Do not rotate/remove older keys before older retained backups expire. GitHub Actions secrets are an additional operational key copy, not replacement for owner's password-manager recovery copy.

## Required setup (owner-controlled)

1. In Supabase acloud-staging SQL editor as database owner, run the privately generated setup-backup-role.sql once. It creates a separate login and SELECT/default privileges, no table/data mutation. Do not paste its password or contents into chat/Git.
2. In Jabia01/Acloud GitHub Settings > Environments create staging-backups, restrict deployment branches to main, retain trusted repository write access only. Scheduled jobs require access without per-run human review; if required reviewers block runs, backups will wait for approval.
3. Environment secrets (all private, never source-controlled):
   - BACKUP_SOURCE_JSON: private backup-source.json, includes role password and public CA.
   - BACKUP_B2_JSON: private b2-backup-credentials.json, restricted to private backup bucket/database/ prefix.
   - BACKUP_ENCRYPTION_KEY: owner's existing 64-hex recovery key (newline trimmed).
   - BACKUP_ALERT_RESEND_KEY: sending key for approved Resend domain; prefer a dedicated sending-only key.
   Environment variable BACKUP_ALERT_FROM: existing verified sender address; alert recipient is hardcoded to owner-approved privacy mailbox.
4. Install this folder as infrastructure/backup and workflow as .github/workflows/staging-backups.yml. Explicit owner push authorization required; exclude unrelated app/native work/private files.
5. First run manually with daily and force_restore=true. Inspect sanitized PASS record; verify inbox test/failure receipt. Then confirm first scheduled daily and hourly check actually execute. GitHub job minutes/budget need monitoring; no paid spending cap was raised by preparation.

## Manual commands

npm ci --ignore-scripts --no-audit --no-fund
npm test
node run.mjs daily
node run.mjs monitor
node run.mjs restore

Required environment variables correspond to GitHub secrets above. Keep values out of command lines/history/logs; use protected environment injection. Local DOCKER_BIN can point to existing Docker Desktop CLI. No recovery key is included in B2 objects or workflow logs. Logs contain only safe statuses/timestamps/counts, no database rows.

## Limits and recovery dependencies

Application schema/database records only: not raw B2 media, global roles/passwords, all Supabase platform schemas, application encryption/signing keys, Railway volumes/independent deletion ledger, or PITR. Existing encrypted original manual backup remains valid with its original key and format. Role/ACL reconstruction, correct secrets, tombstone/ledger replay, session revocation and reviewed B2 bindings are required before real restored traffic/jobs. Monthly localhost restore does not prove those hosted cutover steps.

## Tested evidence

Policy/encryption/retention negative tests and downloaded-snapshot isolated restoration are recorded in the project progress ledger. Source least-privilege identity, actual GitHub schedule and delivered failure notification remain pending until activated and observed. Do not infer scheduled protection from these files alone.

## Alert delivery test

Dispatch the existing protected workflow with mode `alert-test` to send a clearly labelled test notification through the same sender used for backup failures. This mode reads only the alert key/from/to settings; it does not connect to the source database or backup bucket, trigger an outage, or change a success marker. The log reports the provider message ID and acceptance. Confirm delivery status and actual inbox receipt separately; provider acceptance alone is not inbox confirmation.

## Temporary B2 failures

Safe authorization/list/download calls and encrypted uploads make at most five attempts on HTTP408/429/500/502/503/504 or selected transport timeouts/resets. Backoff starts at one second, doubles and adds bounded jitter. Retry-After is respected up to sixty seconds; a longer requested wait fails rather than retrying too soon. Upload retries obtain a fresh B2 upload URL/token and send the same scoped encrypted bytes/checksum. A lost response can leave an extra encrypted object version; the returned exact version is still downloaded and verified before success, and ordinary retention handles old versions. Retention deletion calls are not automatically replayed. Credential, TLS, scope, response-binding, decryption and integrity failures remain terminal.

Provider upload behavior: https://www.backblaze.com/apidocs/b2-upload-file
