# Mobile transfer notifications

The iOS app supports opt-in local notifications. Enable **Account → Notifications → Transfer alerts** and allow the system permission. **Send test notification** schedules a clearly labeled test five seconds later; lock the device to check presentation.

Alerts cover server-verified ordinary backups, fully protected media manifests, successful ordinary/compound Photos restores and problems requiring attention. Intermediate uploads, partially protected media, normal network waits and cancellations do not announce success. Messages contain no media names, previews, account details or permanent/signed object URLs. Tapping a transfer alert opens Backup or Restore.

State tracking uses the complete durable queue rather than the visible history page. Initial history is silent, unchanged outcomes are deduplicated across relaunch, and pending/delivered alerts are cleared on opt-out or sign-out. Switching accounts stops the previous backup worker before logging in. Notifications never change backup/restore protection or delete originals.

## Validation

Run from the repository root:

```sh
swiftc apps/ios/Sources/TransferNotificationPolicy.swift scripts/test/mobile-notifications.swift -o /tmp/acloud-notification-policy-tests
/tmp/acloud-notification-policy-tests
```

Policy regression checks and signed Debug / unsigned Release compilation passed on 2026-10-16. The updated app was installed in place on the paired iPad. Physical lock-screen receipt, permission denial/opt-out and notification tap navigation remain pending device acceptance.

## Limitations

These are local alerts, not APNs/server push. The app must receive execution time to observe outcomes and schedule alerts. Supported background-upload reconciliation awaits scheduling before its completion callback; force-quit or suspended apps cannot receive new server-originated events through this feature. iOS permission, Focus and presentation settings control visible delivery. Scheduling alone does not prove receipt.
