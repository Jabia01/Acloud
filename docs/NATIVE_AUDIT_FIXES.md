# Native audit fixes — October 2026

Backup connection and refresh results carry an account-session generation. Sign-out suspends connections and invalidates old results before asynchronous teardown; successful sign-in reopens the connector. Stale queue and manifest results cannot repopulate the signed-out UI.

Release explicit media selection resolves an existing source version through the manifest planner, including settled cancellation replacement. Unchanged versions reuse resources; edits remain independently eligible for backup.

Library thumbnail requests include Photos modification revision and requested size. Retained gallery cells reload changed local appearances; saved verified backup previews remain separate.

Validation: 106 BackupEngine tests and six release-safety checks passed. Release compilation succeeded. The owner confirmed installation and refresh/thumbnail behavior on the iPad. Background uploading was also previously confirmed working. Specific background completion-alert receipt is a separate acceptance case.
