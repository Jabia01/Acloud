# Native wording cleanup — 20 October 2026

Shortened Backup, On device, Saved, Storage, Account and notification settings. Removed normal-screen staging/development/test-acceptance messages and repeated beta/original warnings. One beta notice remains in Account, with practical warnings preserved at failures, restore and device-copy removal.

- Banners retain their established styling; Backup now says “Back up your memories” rather than implying it frees device space.
- File counters still count files and say “Files protected”; they are not misrepresented as logical photo/video counts.
- Restores use plain original/edited-version labels, retain the iCloud sync notice, and state that edit history is not restored.
- Older-backup manual preview action explicitly says it may download the original. Size limits and security checks are unchanged.
- Diagnostic tab, generated-file control and redundant diagnostic pickers are hidden by default, accessible through Account → About Acloud → Diagnostics in Debug only. A hidden diagnostics-tab selection returns to Backup.
- Pause all, Resume all and Retry failed are available with relevant transfer states, rather than being confined to developer controls.
- Storage's unit explanation is collapsed. Free Up Space availability is described according to its actual enabled state. No deletion gate changed.

Existing backup-selection and Release-safety checks passed. No new mirrored-copy tests were added for these reversible text changes. Full simulator app build passed. Signed clean-source build/installation is recorded separately when complete.

Unrelated existing AccountView refresh work is preserved in the working tree and excluded from this change's commit.
