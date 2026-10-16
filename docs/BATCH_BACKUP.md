# Native multiple-item backup selection

Backup → **Choose photos and videos** opens an ordered system Photos picker with a maximum of 10 selections. Select the desired items and confirm Add. Debug also offers Photos only and Videos only shortcuts, each with the same selection cap. Cancelling the picker queues nothing.

Only explicitly selected identifiers are processed. Input identifiers are deduplicated in selection order. Missing Photos identifiers are counted as inaccessible and never queued. Each selected item is handled independently; one unsupported/inaccessible/failed item does not discard the remainder. The result alert reports added, existing, unsupported, inaccessible and failed counts without displaying or logging Photos identifiers.

The Debug test adapter retains ordinary-photo/unedited-video restrictions (video duration at most 30 seconds), account/device/library binding and persistent queue deduplication. Server-enforced project-window allowance, item-size limits, quota, authorization and integrity gates remain unchanged. Originals are retained. iCloud originals are downloaded only under the existing explicit policy. Selecting multiple items does not enable complex-media acceptance, public beta admission or Beta Release background uploads.

Verification on 2026-10-16: new batch policy regression executable passed (maximum, stable deduplication, mixed outcomes, missing access and continuation); three existing queue identity, date-pagination and server-verification tests passed; signed Debug and unsigned Release builds passed. Physical multi-item backup completion remains pending user acceptance.

```sh
swiftc apps/ios/Sources/BackupSelectionPolicy.swift scripts/test/backup-selection.swift -o /tmp/acloud-backup-selection-tests
/tmp/acloud-backup-selection-tests
```
