# Storage capacity and transfer recovery

Implemented locally on 22 October 2026. Publication and physical-device acceptance remain pending.

## User behavior

- Backup distinguishes an exhausted Acloud allowance from insufficient device space. Storage reports the two separately. Backup shows the latest reported cloud space before selection; the server remains authoritative and stale client data does not block idempotent retries.
- Restore checks estimated device capacity before downloading and again before saving to Photos. Normal and complete-media restores pause with a device-space recovery message. No original is automatically removed.
- Estimates allow two copies plus 64 MiB before restore, and one copy plus that margin immediately before saving. Backup checks known preparation size and each upload part with the margin. Unknown capacity estimates do not deny the operation; actual filesystem full errors are classified separately.
- Resuming a paused restore reauthorizes the same saved version and verifies an existing complete download before reusing it. An uncertain Photos save still requires reconciliation.
- Website downloads explain that device space and cloud allowance are separate. Browsers do not expose a reliable system-wide free-space check.

## Cloud reservations

Quota enforcement remains atomic and server-side. A quota denial exposes only the specific quota code and bounded required/available byte counts; unrelated internal errors remain sanitized.

Cancellation bounds the upload session expiry to at most six minutes after its first cancellation: the maximum five-minute upload permission lifetime plus a one-minute clock allowance. It does not extend an earlier expiry. Repeated cancellation cannot extend the hold. Reservations remain held until that expiry because previously signed uploads may still arrive. Expiry processing on summary/worker execution releases them idempotently; six minutes is the eligibility bound, not a promise of cleanup while processing is unavailable.

Failed resumable transfers retain their reservation until cancellation or expiry. Protected objects and original device files are not deleted or changed by these capacity checks.

## Verification

Passed API build and unit suite (29 tests), website production build and unit suite (143 tests), followed by 18 focused dashboard/download tests including the additional capacity-render test, MediaPreservation suite (55 tests), BackupEngine suite (117 tests plus three targeted capacity checks), and RestoreEngine suite (113 tests plus targeted complete-media coverage). Native simulator build passed; the final PhotoKit disk-full classification adjustment is also build-checked. Secret scan clean apart from the existing allowed example values.

Three additional PostgreSQL integration cases cover quota denial without reservation, cancellation expiry/idempotent release, and preservation of protected bytes when a failed upload is cancelled. They could not run locally because the Docker engine did not respond. They must pass before publication is treated as verified.

Physical iPad testing, installation, and publication are not completed by this local change. Railway key rotation remains a separate pending task.
