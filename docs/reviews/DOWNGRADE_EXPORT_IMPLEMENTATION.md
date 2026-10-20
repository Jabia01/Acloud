# Downgrade and account export update

## Implemented behavior

- New lower-quota selections use POST /billing/plan-change. They do not create a checkout or payment transaction. Exact active provider prices are verified server-side, with authenticated owner/session checks, existing payment admission and per-user transaction locking.
- Protected plus reserved bytes must fit the target. New reservations respect the scheduled target while the current paid entitlement remains in place. Undo and replacement are supported before period end.
- Before acknowledging a schedule/undo request, the API confirms the previous renewal is disabled; the worker retries its cancellation idempotently and provisions the replacement at the paid-period boundary. A signed event or independent provider verification must prove the exact customer, amount, currency, environment and timing before the smaller paid allowance activates. Failed/missing payment does not silently grant a new paid period.
- Cancellation clears an unpaid scheduled change. Previously prepaid scheduled changes retain their historical semantics and require support review rather than losing an already collected payment.
- Migration 018 adds scheduled_prepaid with a true default for historical rows. Apply this additive migration before deploying the new API/worker. No existing subscription or entitlement is changed by the migration.
- Account export history is server-owned and recoverable after refresh. Status and expiry are shown without exposing encrypted payloads or credentials. Account records can be assembled into a verified JSON download with a 32 MiB browser bound and individual-file fallback. Original media remains separate.
- Selected-original downloads use existing short-lived private authorization, up to the existing five-item/500 MiB selection bound. Requests do not prove that a browser saved the originals. Existing owner/device and beta download restrictions remain.
- Admin billing shows estimated excess and free-account storage costs. The existing observability pipeline records a budget alert when estimated free-account storage plus paid-account excess exceeds the configured monthly budget. Alert delivery still depends on the configured AlertSink and running observability job. Estimates are not provider invoices and exclude copies, old versions, thumbnails, traffic, tax and hosting.

## Retention policy boundary

Automatic removal after downgrade/cancellation remains disabled. The proposed 60-day recovery period is not an active customer deletion deadline. Before enabling it, implement policy acknowledgment, notices/reminders, selection of retained items, fully usable export/recovery, holds, audit and verified object-version deletion. Never apply a bucket-wide age rule to protected customer media or imply archiving stops storage charges. Device originals must never be removed by this flow.

Existing stale-upload and expired-export cleanup is governed by its current switches and approved retention policies; this update does not enable those switches or delete customer objects. Do not describe the alert budget as an enforced spending cap.

## Release procedure

Run billing, export/lifecycle and web checks; verify the additive migration against an isolated database. Take/verify a recovery backup before a hosted migration. Publish only with explicit user authorization. Apply migration 018 using the restricted staging migration role, deploy API/worker/web, and verify an owner TEST schedule/undo/cancel plus account export. Do not test by charging a live customer.

Rollback code may ignore the additive column, but review any unpaid scheduled changes first: older code assumes every scheduled change was prepaid. Never roll back while unpaid scheduled changes remain without reconciling them. Do not remove historical payment evidence or lower a quota manually to simulate payment.
