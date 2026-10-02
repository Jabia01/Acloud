# ACL-003: local photo-library discovery

This stage reads accessible image/video metadata and stores local observations.
It does not transmit identifiers or metadata to the API, read original bytes,
create thumbnails, modify/delete Photos assets, or create backup/cloud states.
ACL-004 is not implemented. Display branding remains configured; domain/package
names are neutral. Discovery works independently of account authentication.

## Permission model

`PhotoKitLibrary` implements `PhotoLibraryProvider`: authorization, explicit
request, stable scan snapshot and change observation. `.readWrite` is Apple's
minimum access level that permits reading Photos assets; `.addOnly` cannot read
the library and there is no separate read-only access level. The implementation
contains no write APIs. See [Apple access levels](https://developer.apple.com/documentation/photos/phaccesslevel).

| State | Behavior |
| --- | --- |
| notDetermined | Explanation and Allow Photo Access. No automatic request/scan. |
| authorized | Scan accessible non-hidden image/video assets; summary/re-scan. |
| limited | Same scanner over the granted set only, prominent limited label and incomplete-library explanation; Apple limited picker and Settings. |
| denied | No fetch or repeated prompt; explanation and Settings. |
| restricted | No fetch/prompt; explain device/parental controls. |

Requests are coalesced and only made while notDetermined. The Info.plist usage
description explains metadata discovery and absence of upload/modification.
`PHPhotoLibraryPreventAutomaticLimitedAccessAlert` disables automatic limited
reminders in favor of the explicit picker. The picker uses
`presentLimitedLibraryPicker(from:completion:)`; its completion and dismissal
refresh authorization/snapshots. Foreground return from Settings always refreshes.
No application identifier is shown in the UI. Photos permission is independent
of the local-network permission used by the existing development API screens.

## Architecture and performance

- `DiscoveryCore`: Sendable domain models/protocols, `PhotoLibraryScanner` actor,
  `SQLiteDiscoveredAssetStore` actor, pure original-component size policy.
- `PhotoKitDiscovery`: `PhotoKitLibrary` authorization/change actor and private
  `MetadataSnapshot` actor; no Photos imports in core.
- `PhotoLibraryAccessUI`: iOS/UIKit-only PhotosUI picker adapter, explicit iOS 15
  availability and main-actor completion delivery (ACL-003M-A compile repair).
- `DiscoveryViewModel`: main-actor UI projection, one scan task, cancellation,
  pending re-scan coalescing, foreground refresh and access invalidation.
- `DiscoveryView`: summary, permission explanations and scan controls.

The native `PHFetchResult` retains framework-managed fetch metadata; it is not
converted into an array of all assets. Fetch images/videos only, exclude hidden
assets deliberately, include individual burst assets. Counts can differ from
Photos UI album totals. A snapshot actor copies at most 250 metadata rows by
default (hard cap 1,000); an autorelease pool drains each batch. Neither images
nor video resources are materialized. Photos enumeration and SQLite operations
run on actors off the UI actor. Progress is O(1), with counts/size aggregates
queried only on completion/cancellation. Upserts use indexed keys and prepared
statements in one transaction per batch; no repeated linear duplicate searches.
Total work is O(n log n) including index updates, not O(n²). Native Photos fetch
memory and real-device throughput still require measurement; no benchmark has
been executed on Windows.

Cancellation is checked before/after fetch and before final reconciliation.
Batch rows and next-offset checkpoint commit atomically. Cancelled scans report
partial totals and do not mark unseen rows unavailable. Resume can reuse the
same process/session, revision and authorization snapshot at its committed
offset. A Photos change, access-set change or foreground refresh invalidates
that cursor. On app restart a new process UUID forces a fresh metadata pass;
existing rows/first-seen timestamps remain. This avoids pretending that a stored
Photos fetch index is stable across launches. No originals are reread/downloaded.

## Local persistence and identity

Native SQLite is available on iOS 17, requires no third-party persistence
dependency, supports transactional checkpoints and aggregate queries for
100,000+ observations. The SPM CSQLite shim links the SDK's sqlite3. Versioned
schema 1 is in `SQLiteDiscoveredAssetStore.swift`; higher unsupported versions
are rejected rather than reset. Future destructive local migrations require a
documented recovery strategy. There are no new server migrations/tables.

Application Support/Discovery/metadata.sqlite is excluded from iCloud/device
backup. The directory, database, WAL and SHM use complete iOS file protection.
Scan tasks cancel when the scene becomes inactive/background; locked-file
errors produce a generic retry message without paths/SQL/media metadata.
WAL + FULL synchronization preserves batch/checkpoint atomicity. This metadata
is private application data, not a media cache. SQLite's internal cache is
bounded; no full-library Swift dictionary is maintained in the app.

Each row contains PhotoKit local identifier, image/video type, nullable dates,
dimensions, video duration, known resource bytes, visible/unavailable state,
first/last-seen timestamps and scan generation. Availability is always unknown:
resource size cannot prove that originals are on-device. Missing values remain
null; image duration is null. No filenames, filesystem paths, location/EXIF,
thumbnails, originals, object keys or upload/protection fields are stored.
The checkpoint records generation, process-local snapshot key, authorization,
total, next offset, newly discovered count and running/paused/complete status.

`PHAsset.localIdentifier` correlates observations only inside this installation's
Photos library; it is not promised to survive library replacement, asset
deletion/reimport, reinstall/restore or cross-device synchronization. Excluding
this cache from backup avoids restoring another installation's stale identity.
No comparison across devices or use as a server primary key is permitted.

| Future relationship | Identity rule (documentation only) |
| --- | --- |
| Account → Device | Existing account-owned registered device; no media sent now. |
| Device → local Photos observation | Installation/library-scoped local identifier and metadata; optional planning correlation within that scope. |
| Future backup asset | Independently assigned server identity owned by account; device correlation is not deduplication proof or sole identity. |
| Future backup asset → cloud object | Separate private object identity/integrity record, server-authorized later; no permanent public URL, object key or credentials introduced here. |

## Resource size and iCloud limitations

The default iOS 17-compatible build returns **unknown** for all resource sizes.
Apple's public nullable [`PHAssetResource.dataSize`](https://developer.apple.com/documentation/photos/phassetresource/datasize-5lxva)
metadata property starts at iOS 27 (verified in Apple's documentation metadata).
An optional `PHOTOKIT_RESOURCE_SIZE_METADATA` Swift compilation condition allows
using it only with a supporting SDK and an iOS 27 runtime availability check.
It is off by default and uncompiled/unexecuted here. Older SDKs/runtimes never
fall back to KVC `fileSize`, URLs, media loading, guessed dimension-based byte
counts or an iCloud download.

When opted in, original photo/video/pairedVideo/alternatePhoto component sizes
are summed only when every original component exposes a nonnegative size.
Missing components/metadata/overflow result in null. Edited/full-size derivative
resources are excluded to avoid counting both original and edited variants.
Live Photo still+motion and RAW/JPEG alternatives must be checked on device:
the result is a resource-byte total, not a measured disk footprint, Photos
storage usage or definitive future transfer size. A zero known size remains
distinct from null. All unknown totals display Unknown rather than 0 GB.

Dates/dimensions/duration/local identifiers may exist for iCloud-optimized assets
without their originals being on the phone. No public content-free check used
here establishes local availability, so it remains unknown. No content request
or network-capable PhotoKit resource manager is used, and this layer never
requests downloads. Photos/iCloud's own independent synchronization is outside
the app's control. Known sizes are not labelled local bytes or cloud storage.
Partial scans, limited access and unknown-size counts are surfaced separately.
Future transfer architecture must explicitly handle original retrieval,
network consent/cost, interruption and server integrity verification under a
later specification; discovery never marks anything PROTECTED.

## Changes, reconciliation and privacy

An NSObject adapter registers `PHPhotoLibraryChangeObserver` once a readable
fetch starts. [Apple change observation](https://developer.apple.com/documentation/photokit/observing-changes-in-the-photo-library)
delivers callbacks on arbitrary queues; the actor serializes fetch-result
updates, revision invalidation and the main-actor notification. Incremental
index arrays are disabled; events coalesce into a full **batched metadata**
reconciliation, avoiding huge inserted/removed Swift arrays. This catches added,
removed and metadata-changed assets; Settings/picker/foreground refresh handles
permission scope changes and missed background events. Frequent changes may
restart a scan; no stale snapshot is deliberately finalized.

A completed stable scan marks previously unseen records unavailable; it never
hard-deletes rows. Access revocation/snapshot invalidation clears cached visible
counts and invalidates checkpoints. An unavailable record could mean deletion,
limited-scope removal, hidden status or permission loss. It is **never** consent
to delete a future server backup. Limited access is not inferred to be complete.
No discovery logging or analytics, media network requests, gallery, thumbnails,
token persistence or mutations are added. Existing auth remains Keychain-backed.

See [iOS validation plan](IOS_VALIDATION_PLAN.md) for all unexecuted native checks
and [validation record](VALIDATION.md) for actual Windows results.
