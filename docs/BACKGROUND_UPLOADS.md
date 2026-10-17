# Background uploads

Background uploads are enabled by `BackgroundUploadsEnabled=true` in Debug and Beta Release. This does not grant server admission, change quotas, enable automatic photo selection or authorize deletion of an original.

Selected originals are prepared into private app-managed files, then transferred with a background URLSession using file-based upload tasks. Existing Debug session identifiers are preserved across this update; Release session identifiers are scoped to the bundle. The system session can continue a handed-off part while the app is suspended. Brief app execution time is requested for authenticated reconciliation, subsequent part scheduling and server verification. UIKit's background event acknowledgement is called once, with a bounded timeout; ending that acknowledgement does not cancel a system-owned upload.

An active background upload survives a transient disconnected network path. Reconnection triggers queue work, and an available but disallowed cellular/constrained path still enforces the current policy. New part authorizations remain short-lived and are obtained from the authenticated API. Existing queued transfers and server part listings remain the recovery authority.

The backup connector opts the existing session into `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. The token stays in the non-synchronizing, device-only Keychain; it is not copied to files, defaults or notifications. Existing accessible sessions are migrated when the connector reads them. Managed upload files retain first-unlock file protection and are excluded from device backups. A device restart requires the owner's first unlock before credentials or files are available.

The verified-outcome callback scans durable queue/manifest state and schedules the existing privacy-preserving local notification as soon as an item is verified, rather than waiting for all other selected transfers. Uploaded bytes alone never generate a Protected alert. Existing opt-out, account-scoping and notification deduplication remain enforced.

## Limits and device acceptance

Leaving the app, switching apps or locking the screen differs from force-quitting it in the app switcher. iOS controls execution and session scheduling; force-quit, expired authentication/authorization, unavailable originals and prolonged offline periods can require opening Acloud again. Preparation of another original and iCloud retrieval are not an unrestricted background-photo-library sync. This feature does not add APNs/server push or a background timer service. Notifications require the existing user permission and transfer-alert setting.

Pending physical acceptance for this update:

1. With transfer alerts enabled and Wi-Fi connected, explicitly select a disposable local video. After its upload starts, leave Acloud and lock the iPad. Verify the item completes and a Backup verified notification arrives without reopening Acloud.
2. Tap the notification and confirm Backup opens with the item Protected; restoring that item must still use server integrity proof.
3. Repeat with a connection interruption, restore allowed Wi-Fi, and check recovery without pressing Resume. Confirm Wi-Fi-only policy does not use cellular.
4. Check relaunch reconciliation, opt-out, and sign-out cancellation. Force-quit must not be described as uninterrupted upload support.

Physical receipt is not established by compilation or unit tests. Distribution signing/TestFlight admission remains separate.

References: [Apple background URLSession guidance](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background), [background execution time](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time), [device-only first-unlock Keychain access](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly).

## Connection-drop recovery

A background multipart step that receives `URLError.networkConnectionLost` (`NETWORK_-1005`) gets up to two bounded recovery passes within the current worker, rather than depending only on the foreground polling timer. After a short cancellation-aware delay, storage part listing is checked first. An accepted part is retained; a missing part receives fresh authorization before retransmission. User pause/cancel and network policy are rechecked. Persistent failures use the existing durable retry/backoff state; this is not a promise of continuous execution after force-quit or while iOS withholds execution. Server verification remains required for Protected and completion alerts.

## Starting queued work

Explicit selection, retry, resume and restart request queue execution immediately, before history/manifest refreshes. Requests arriving while a worker is running trigger another pass after its current work and refresh finish. Periodic recovery scheduling lives at the app tab-container level, so changing tabs does not remove it. The timer is only a foreground fallback; it is not an iOS background-execution entitlement. Preparing originals and handing a file to the background session must still occur before system suspension. Physical locked-screen completion remains an acceptance check, not a conclusion from successful builds.

## Interruption diagnostics

Failed attempts now persist a bounded app-defined stage alongside the existing sanitized error code. Details & support shows “Stopped while…” to distinguish original preparation, session setup, authorization, byte transfer, part reconciliation and verification. No media identifier, filename, URL, credential or server body is added. Old records decode with no stage, and explicit retry/resume clears stale stage details. This is diagnostic coverage; physical background completion remains unconfirmed until an actual locked-device run succeeds.
