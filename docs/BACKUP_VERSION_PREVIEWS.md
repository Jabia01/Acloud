# Backup version previews

A saved backup is a checksum-verified, version-pinned object. The current appearance of a source PHAsset is not a preview of its stored bytes: later edits may change the device rendition while the cloud version stays unchanged. Protected rows never use current PHImageManager thumbnails.

## Native saved thumbnails

After server verification and before upload staging cleanup, a presentation-only preparer re-reads the protected queue record. It derives a thumbnail from the exact upload file only when file size and SHA-256 match the protected record. Photo thumbnails honor orientation; video thumbnails use a frame from the verified file. Both are at most 240 pixels on the longest side, JPEG without source EXIF, and capped at 256 KiB. Preview failures never prevent normal staging cleanup, grant protection or alter backup state. Local generation is bounded to source files up to 256 MiB.

The cache key includes account ID, cloud asset ID and verified source checksum. It lives in the app's private caches directory, is excluded from device backups, uses 0700 directories/0600 files and complete iOS file protection. Disposable disk previews are limited to 32 MiB; in-memory row loaders are bounded and cleared on sign-in/sign-out. In-flight preview downloads are cancelled and stale results suppressed on account changes. Source device edits do not overwrite a checksum-bound thumbnail.

For older backups without a cached thumbnail, **Load saved thumbnail over Wi-Fi** explicitly downloads the saved original (up to 32 MiB). It uses existing authenticated restore evidence and authorization, exact storage-origin checks, HTTPS/certificate verification, no redirects, Wi-Fi/non-expensive/non-constrained access, pinned version, exact size and streaming SHA-256 validation, then server recheck. Only one preview download runs at a time. The original is removed after generation; no Photos item is created. There is no new public endpoint or permanent storage URL. Restore/account/device/format gates remain in force: older complex resources may be unavailable while complex restore is gated. Larger sources or unsupported formats retain a neutral icon. Re-download is explicit after cache eviction.

Local preview creation works for newly completed ordinary and complex resource backups on this device. Manifest rows use an eligible protected still/render resource. Restore catalog rows resolve the server's evidence before looking up the same checksum-bound cache. This is a device cache, not server-hosted thumbnail synchronization; thumbnails do not automatically appear on another device without an eligible download.

## Validation

Generated-image tests exercise the actual preview renderer/cache: bounded 240-pixel output, source edits leave an existing thumbnail unchanged, mismatched bytes and invalid image inputs are rejected, account/version cache isolation, private file permissions. Policy tests reject malformed cache keys, unprotected/missing/mismatched evidence and oversize sources. Signed Debug and unsigned Release build results and physical installation are recorded in the project ledger. Actual iPad photo/video appearance still requires on-device acceptance; compilation is not visual proof.

2026-10-16 earlier investigation streamed the latest three ordinary protected staging photo versions only for hash validation, without saving/rendering customer photos. Their pinned version, size, upload SHA-256 and verification records matched. That receipt does not identify the particular photo the owner edited or visually establish its original colour.
