# Transfer UI usability pass — 2026-10-16

Native Backup and Restore now use a shared stage display: Upload → Verify → Protected and Download → Check → Save to Photos. Byte percentages describe transfer only, are clamped to 0–100%, and never grant protection or Photos-save completion. Preparation, waiting, checking and saving use the actual state label without invented percentages or estimated completion times. Paused/failed transfers retain byte progress without showing completed stages.

Backup separates verified files, queued/active files and paused/attention files. Media and status filters operate on the currently loaded page, reset when new media is queued, and do not alter queue execution or pagination. Live Photo/edit completeness has a required-file verification bar; the manifest state still determines the protection label.

Restore shows the selected count, media mix and size in a selection panel, with a count-labelled restore action. Controls are disabled while the model is busy. Stored-version placeholder copy is now “Saved version · no preview yet”; current device thumbnails remain excluded from stored-version rows.

Validation: signed Debug build using the existing saved Xcode project; unsigned Release build; whitespace check. Device installation is recorded in the project ledger. On-device visual/dynamic-type and live transfer walkthrough still require observation; compilation is not visual acceptance. No network, engine, authorization, original-deletion or background-upload policy changes.
