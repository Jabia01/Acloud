# Mobile transfer notifications

The iOS app supports opt-in local notifications. Enable **Account → Notifications → Transfer alerts** and allow the system permission. **Send test notification** schedules a clearly labeled test five seconds later; keep Acloud open to check a foreground banner, or lock the device to check lock-screen presentation.

Alerts cover server-verified ordinary backups, fully protected media manifests, successful ordinary/compound Photos restores and problems requiring attention. Intermediate uploads, partially protected media, normal network waits and cancellations do not announce success. Messages contain no media names, previews, account details or permanent/signed object URLs. Tapping a transfer alert opens Backup or Restore.

State tracking uses the complete durable queue rather than the visible history page. Initial history is silent, unchanged outcomes are deduplicated across relaunch, and pending/delivered alerts are cleared on opt-out or sign-out. Switching accounts stops the previous backup worker before logging in. Notifications never change backup/restore protection or delete originals.

## Validation

Run from the repository root:

```sh
swiftc apps/ios/Sources/TransferNotificationPolicy.swift scripts/test/mobile-notifications.swift -o /tmp/acloud-notification-policy-tests
/tmp/acloud-notification-policy-tests
```

Policy regression checks and signed Debug / unsigned Release compilation passed on 2026-10-16. The updated app was installed in place on the paired iPad. The owner confirmed locked-iPad receipt, tap navigation and opt-out on 2026-10-16. Foreground banner receipt after the later implementation still awaits device confirmation.

## Limitations

These are local alerts, not APNs/server push. The app must receive execution time to observe outcomes and schedule alerts. Supported background-upload reconciliation awaits scheduling before its completion callback; force-quit or suspended apps cannot receive new server-originated events through this feature. iOS permission, Focus and presentation settings control visible delivery. Scheduling alone does not prove receipt.

## Foreground banners

The notification delegate now requests banner, Notification Center list and sound for recognized Acloud events while the app is foregrounded. It rechecks the app opt-in at presentation time and requires an active matching transfer scope; unknown events or stale signed-out scopes are suppressed. Test notifications require an explicit current test request, cleared on sign-out/opt-out. iOS permission, Focus and sound settings still control presentation. No historic completion replay is introduced. Updated policy regressions and signed Debug/unsigned Release builds passed on 2026-10-16.
