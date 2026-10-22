# Password and session recovery — 22 October 2026

Local changes only. No production credentials were changed, recovery emails sent to real users, hosted feature gates opened or deployments triggered. The earlier account-deletion fixes remain a separate unpublished local commit; key rotation remains pending.

## Changes

- Missing, malformed, expired or already-used password/verification links have direct recovery links. A public verification-resend page uses the existing enumeration-safe API. Fragment tokens are validated, kept in component memory and removed from the address bar. Duplicate token parameters are rejected. Successful reset/verification clears the token and form, removes the submission form, and offers sign-in rather than allowing a repeat submission.
- Customer library, thumbnail, preview and billing expiry redirects retain an allowlisted return page. Saved-item detail paths accept only the application's UUID format. External destinations, query capabilities and traversal fall back to Dashboard. This does not promise to preserve navigation context across a recovery email opened in another browser; email links without a supplied return destination use the default.
- API 401 during backup pauses with AUTHENTICATION_REQUIRED, without consuming retry attempts or resetting the upload key, server upload/asset references, accepted-part evidence or original. After signing back into the same account/device, the user resumes the queued backup; normal idempotent server reconciliation decides which parts remain. Automatic resume immediately after signing in is not introduced.
- API 410 retains its existing persisted SESSION_EXPIRED code for compatibility, but the UI now correctly explains that the upload window expired and a new attempt is needed. It does not present this as expired sign-in. Private-storage 401/403 remains an upload-permission refresh failure, distinct from application API authentication.
- Account refresh bypasses its normal throttle when the visible backup queue requires sign-in, so a recently cached account view does not hide the recovery form. Queues remain scoped to their existing account/device.
- Native authenticated failures clear only the credential actually used. Keychain compare-and-clear, reads and writes share a process lock across store instances. Logout is bound to the captured credential. A late old-session failure/logout response cannot clear a newer sign-in. Failed login remains unable to clear an unrelated existing session.

## Existing server safeguards verified

The database suite verifies token hashing, generic recovery responses, expiry, single consumption, old-link invalidation, revocation of all existing sessions on reset, rejection of the old password, and fencing of a login that verified before a concurrent reset. A new generated-data case proves upload IDs, accepted parts, reserved cloud bytes and the device binding survive password reset, while old sessions fail and a fresh login works.

## Validation

- 28 PostgreSQL authentication integration tests passed in a disposable database, including the actual HTTP rate guard and new upload-preservation case. The first run's rate-window expectation failed while the long native stress run was active; a complete rerun passed without changing or weakening the rate guard.
- 25 HealthClient tests passed, including late unauthorized/logout response and Keychain conditional-clear cases.
- 118 BackupEngine tests passed after correcting fixture assertions for repeated idempotent create requests and nondeterministic concurrent-part completion order. The unchanged 100,000-record queue stress case passed in the earlier full run and was excluded from the rerun; it was unusually slow on this machine. No production scale limit was changed.
- 153 website tests passed, including malformed/duplicate link tokens, recovery actions, verification resend and safe return destinations. Website production build passed.
- Complete native simulator build passed. Secret scan found no unexpected findings (only four existing approved examples). Detailed logs are recorded in the project-audit handoff.

Physical-device recovery, installation and hosted acceptance remain pending. No real owner account was used as a password-reset or deletion fixture. Neither recovery tokens nor credentials are included in this document.
