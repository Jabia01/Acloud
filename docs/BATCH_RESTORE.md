# Native batch restore

Restore supports explicit selection of up to 10 currently visible eligible items. Select individual rows or choose **Select up to 10 visible items**, then **Restore selected to Photos**. Clear selection resets the batch. Photo/video filtering applies to the select-visible action.

Debug private testing retains the server-provided account/device/window asset allowlist; the old single-item client restriction is removed only within that existing scope. The legacy single-asset development path remains limited by its one-element allowlist. No backend authorization, quota, integrity or Photos-save safeguards are weakened.

Each selected item receives its own durable restore queue entry. Existing active/saved duplicates are skipped unless the user explicitly confirms another copy. A queueing failure for one item does not stop other eligible selections: successful and duplicate selections are removed, failures remain selected for review. The UI reports counts without logging private media details. System Photos add permission is still required.

Unavailable restore access now has its own empty-state guidance; it must not claim the user's protected cloud media is absent. The server restore safety switch remains separate from the UI code.

Validation (2026-10-16): batch selection boundary/scope checks passed; 7 existing duplicate/account/library isolation regressions passed; signed Debug and unsigned Release builds passed; iPad updated in place. Physical batch completion acceptance remains pending.

```sh
swiftc apps/ios/Sources/RestoreSelectionPolicy.swift scripts/test/restore-selection.swift -o /tmp/acloud-restore-selection-tests
/tmp/acloud-restore-selection-tests
```
