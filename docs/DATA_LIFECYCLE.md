# Future media lifecycle

Conceptual only; no asset tables, uploads or PhotoKit integration exist yet.

```text
DISCOVERED -> QUEUED -> UPLOADING -> UPLOADED -> VERIFYING -> PROTECTED
```

DISCOVERED records an eligible local original without modifying it. QUEUED
records user intent and pending transfer. UPLOADING records a resumable attempt.
UPLOADED records completion of transfer as reported by the transport or client.
VERIFYING requires independent server validation of private object presence,
ownership, expected byte length, integrity checksum and relevant metadata.
PROTECTED means all required checks have succeeded and durable verification
evidence has been persisted server-side.

**UPLOADED does NOT mean PROTECTED. Only successful server verification can
transition an asset to PROTECTED.** A client cannot set that state. A successful
health check or HTTP upload response also cannot establish protection.

Failure states must include UPLOAD_FAILED and VERIFICATION_FAILED, with bounded
retries and explicit diagnostics free of sensitive content. Interrupted transfers
return to QUEUED using persisted resume state and reconciled quota reservations.
Verification failures remain unprotected until independently corrected and
reverified. Represent missing local originals and lost/corrupt remote objects
explicitly; do not silently preserve a protection claim when evidence is invalid.
Late, duplicate or out-of-order events must not downgrade a later successful
attempt or protect the wrong version. State transitions must be idempotent and
bound to an asset version/upload attempt, with auditable verification evidence.

Restore downloads must validate integrity and preserve original quality and
metadata where possible. Device originals are never automatically removed.
Future remote deletion must be explicitly authorized, auditable and recoverable
within a defined grace period. Subscription failure never implies immediate
deletion; retention and notification rules require a later approved specification.
