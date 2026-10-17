# Restarting a cancelled backup

Cancelled transfers show **Back up again**. Reselecting a cancelled ordinary photo/video also queues a fresh attempt, instead of reporting the cancelled entry as a duplicate.

The coordinator drains old system tasks and resolves pending create/cancel responses before replacement. If server verification already won the cancellation race, the existing verified backup is reconciled rather than uploaded again. An unavailable cancellation acknowledgement leaves the old attempt pending and blocks replacement safely.

For ordinary backups, a SQLite transaction archives only the cancelled row's deduplication key and inserts a new queue item with new queue/idempotency identities and empty upload/proof state. The cancelled record, original identity and history remain intact. Normal duplicate suppression points to the current attempt. Transaction failure rolls back the identity change. Cancelled/protected records still cannot be revived through ordinary queue state transitions.

For manifest-backed items, explicit reselection captures a fresh manifest/resource set after pending cancellation is settled. Existing cancelled and protected versions are not rewritten or deleted. New attempts still require current Photos access, account/device admission, quotas, source checks, fresh authorizations and server integrity verification.

Acceptance: cancel a disposable video, then either tap **Back up again** or reselect it. A new attempt should appear and complete; the old cancellation remains visible. Reselecting the new active/Protected attempt should still be recognized as an existing backup. Also check restarting from an older cancelled history row after more than one cancellation. Originals must remain in Photos.
