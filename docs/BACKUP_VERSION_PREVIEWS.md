# Backup version previews

A saved backup is an uploaded, checksum-verified, version-pinned object. The current appearance of the source PHAsset is not a preview of those stored bytes: Photos can render subsequent edits such as black-and-white even though the stored version is unchanged.

Saved Backup transfer rows, preservation manifests and Restore catalog/history rows now use an explicit backup-version presentation mode. That mode does not request local PHImageManager thumbnails and shows **Backup preview unavailable** until true version-bound previews exist. Pending ordinary transfer rows can still show a clearly labeled **Current device preview**. Known immutable capture dates come from the recorded original/manifest source snapshot; the UI does not infer a stored-version capture date from a mutable local asset. Dates, references, media grouping, sizes, status and controls remain available.

No stored media, original, checksum, storage version, authorization or preservation state is modified by this presentation correction. No new thumbnail download endpoint, public URL, automatic iCloud download or cleanup action is introduced.

2026-10-16 investigation: streamed the latest three ordinary protected staging photo versions only for hash validation, without saving or rendering photos. Exact pinned version, expected/verified size, upload SHA-256 and successful verification records matched for all three. This establishes integrity for those versions; it does not identify which specific image the owner meant or visually establish its original colour. Restoring the exact earlier ordinary backup as a new Photos item is the visual acceptance check.

Signed Debug and unsigned Release compilation passed. Real version-bound thumbnail generation/caching is future work; current-device thumbnails must not be substituted for it.
