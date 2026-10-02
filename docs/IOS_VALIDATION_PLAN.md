# ACL-003 native validation plan — pending macOS/iPhone

Windows source review and Node/PostgreSQL regressions do not validate Swift,
SQLite-on-iOS, PhotoKit permissions, UI or device behavior. The user subsequently
reported successful Mac app build, HealthClient 11/11, PhotoDiscovery 24/24 and
simulator launch/discovery. Those reported prior results have not been independently
reexecuted from this Windows task; the new ACL-004 native checks remain pending.
Use a dedicated test library/device
with synthetic media, not customer photos. Do not log identifiers or media data.

## Compile and automated tests

ACL-003M-A repaired the missing PhotosUI import for the limited-picker extension
by moving presentation into PhotoLibraryAccessUI.swift. On the reported Intel
Mac (Xcode 26.3 / Swift 6.2.4 / macOS 15.7.9), regenerate using the commands below
and rebuild Debug and Release for simulator and generic iOS. Keep the optional
iOS 27 size compilation flag OFF with this SDK. From apps/ios, additionally run:

```sh
xcodebuild -project BackupClient.xcodeproj -scheme BackupClient \
  -destination 'generic/platform=iOS Simulator' -configuration Release CODE_SIGNING_ALLOWED=NO build
xcodebuild -project BackupClient.xcodeproj -scheme BackupClient \
  -destination 'generic/platform=iOS' -configuration Debug CODE_SIGNING_ALLOWED=NO build
xcodebuild -project BackupClient.xcodeproj -scheme BackupClient \
  -destination 'generic/platform=iOS' -configuration Release CODE_SIGNING_ALLOWED=NO build
/usr/libexec/PlistBuddy -c 'Print :PHPhotoLibraryPreventAutomaticLimitedAccessAlert' Configuration/Info.plist
```

The plist value must be boolean true; also inspect the built application's
Info.plist, not just the generated source. Record exact next compiler/test
diagnostics if any. These commands have not executed in the Windows workspace.

On a Mac with Xcode (iOS 17 SDK or newer), Command Line Tools and XcodeGen:

```sh
xcodebuild -version
swift --version
cd apps/ios/Packages/HealthClient
swift test
cd ../PhotoDiscovery
swift test
cd ../..
xcodegen generate
xcodebuild -project BackupClient.xcodeproj -scheme BackupClient \
  -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Run 11 existing HealthClient tests and 24 new DiscoveryCore tests. Confirm all
pass, including 100,001 synthesized assets with batches ≤250 and 401 fetch
calls; measure duration/memory rather than treating that assertion as a native
performance benchmark. Tests exercise real SQLite on macOS but use mock library
providers. Compile PhotoKit adapter and SwiftUI app for simulator and real iPhone;
resolve Swift concurrency/API availability diagnostics before acceptance. Run
Thread Sanitizer on simulator for scan/change/cancel races. CI includes these
steps but has not been triggered or observed here.

Leave PHOTOKIT_RESOURCE_SIZE_METADATA unset for the default build. With an SDK
declaring the iOS 27 `dataSize` API, add that Swift active compilation condition
to the PhotoKitDiscovery target (SwiftPM via `-Xswiftc -D...`, Xcode package build
settings as appropriate), build and run separately. Verify original component
selection for JPEG, HEIC, RAW/JPEG, Live Photo, edited photo/video and slow-motion
video. Compare known resource lengths against controlled source fixtures;
unknown metadata must remain unknown. Record SDK/OS/device versions. Do not
enable this opt-in until that compilation and resource testing passes.

## Real iPhone permission and lifecycle matrix

| Scenario | Required result/evidence |
| --- | --- |
| Fresh install/notDetermined | No prompt on launch or other tabs. Exactly one prompt after Allow Photo Access; usage copy accurate. |
| Full access | Count accessible non-hidden images/videos (burst individuals included); metadata dimensions/dates and video duration match synthetic fixtures. No backed-up/protected text. |
| Limited access | Select a small known subset, count only those assets; limited label and full-library caveat persist after relaunch. |
| Manage limited set | Apple picker opens, cancel returns safely; adding/removing selections updates summary without a second authorization prompt or treating unseen records as deletion consent. |
| Denied | Explanation/Settings, no scanning or repeated request after launch/re-scan/tab changes. |
| Restricted | Simulate parental/device controls; no request loop/fetch; accurate restriction explanation. |
| Settings authorized→limited→denied→authorized | Foreground clears old counts immediately; cancels current scan; updates permissions, fetch revision and counts; no leakage of old full-library counts under limited/denied access. |
| Change permission during scan/picker | No outdated completion/progress projection or incorrect finalization; stable authorized re-scan recovers. |
| iCloud Optimize Storage | Known off-device fixtures remain unknown availability. Scan never requests originals, downloads thumbnails or triggers app media traffic. Default size unknown. |
| Large libraries 1k/10k/50k/100k+ | Measure wall time, peak RSS, SQLite growth and UI frame responsiveness with Instruments. No original-sized allocations or full Swift asset array. Progress/cancel responsive. |
| Video count/duration | Photos/video totals and nullable durations correct for known clips, Live Photos and slow motion; Live Photos count as image assets, paired bytes only in optional size path. |
| Cancel | Mid-batch/mid-scan cancellation commits whole batches only, returns partial label/counts, does not finalize absent rows. |
| Resume same active session | Committed cursor reused when revision/scope unchanged; no duplicate rows/new-count inflation. |
| Background/locked device | Cancel scene task; complete file protection on directory/db/WAL/SHM; no background media scan; unlock returns safe fresh reconciliation. |
| App termination/restart | Persistent rows/first_seen survive; fresh process UUID resets unsafe Photos index and upserts metadata safely. No falsely complete partial results. |
| Add/remove/edit/hidden assets | Change observer delivers and scan reconciles; removed/hidden/limited-excluded rows unavailable, retained locally, no media deletion or server call. |
| Rapid change + cancel/re-scan/tab/foreground | At most one scanner run; callbacks coalesce; no busy loop, stale summary, crash or retained observer/task leak. |
| Empty/fully inaccessible library | Zero accessible counts clearly distinguished from unknown sizes/access denied; no corruption. |
| Storage failures | Locked file/unsupported schema/storage exhaustion produce generic errors; no automatic data reset or identifier/path logging. |

Observe app traffic with Instruments Network/controlled proxy and Photos resource
instrumentation. Existing account/development HTTP may occur; **discovery metadata
and media must never leave the device**. Inspect simulator sandbox SQLite in a
private session without exporting identifiers: rows only metadata, schema1,
no filenames/EXIF/object keys/media BLOBs; backup exclusion and file protection
must be checked on actual iOS (macOS unit tests cannot verify Data Protection).

## ACL-002 authentication regression

Start local PostgreSQL/API/web/Mailpit on the Mac following the repository README.
For device networking use a trusted development host configuration and signing;
do not ship the Debug local-network setup. Test registration/login/account,
Keychain restoration on relaunch, logout, web device/session revocation then
native 401 clearing, locked-device token access and failed logout retry.
Inspect Keychain WhenUnlockedThisDeviceOnly/non-synchronizing configuration;
UserDefaults may contain only the existing non-secret device identifier.
Photos discovery must not copy session tokens, require login or transmit assets.

Record each executed check in VALIDATION.md with date, SDK/OS/device, command,
result and evidence. Any unavailable/failed check stays explicitly pending.

## ACL-004 generated upload native gate — pending

Physical iPhone PhotoKit upload integration remains **UNVALIDATED**. The reported
Mac/iPhone connection problem is still unresolved. No customer-media beta may
rely on simulator or generated-file success as that gate.

On the Mac, run the two existing native packages again and the new package:

```sh
cd apps/ios/Packages/UploadFoundation
swift test
cd ../..
xcodegen generate
xcodebuild -project BackupClient.xcodeproj -scheme BackupClient \
  -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Run all 17 new UploadFoundation cases and existing 35 native cases, then the
Debug/Release simulator/generic-device build matrix above. Native package
compilation, concurrency diagnostics and tests are unexecuted on Windows; do
not assume they pass. Add a development-only harness invoking the foundation
against the Mac's built API/private MinIO using an explicitly generated sandbox
file, the existing Keychain token store and an explicitly trusted storage origin.
The production app has no new automatic upload or PhotoKit-original path.

Check generated 3 B/4 KiB/512 KiB/5 MiB files and rejection above 5 MiB; incremental
SHA-256; strict generated-directory bounds/symlinks/source mutation; QUEUED →
UPLOADING → UPLOADED → VERIFYING → server PROTECTED; API bearer never sent to S3;
expired/foreign-origin/redirected authorization rejected; real network interruption
and cancellation; lost PUT/create response reconciliation; idempotent re-run after
restart; no cancelled callback revives a record; protected state requires matching
server asset ID and byte count; protected record cannot trigger deletion.

Inspect private atomic queue JSON, backup exclusion and complete file protection;
confirm no bearer, presigned URL, provider key or media content persists there.
Test locked/background behavior and network/account 401 clearing through Keychain,
not UserDefaults. Cancel/retry after a missing create response without sending
bytes. Prove the existing discovery screen still never automatically enqueues
Photos assets. Use Instruments for memory/task cancellation and a controlled
network capture with synthetic data only. The ≤5 MiB whole-file retry design is
not resumable large-video backup or background entire-library orchestration.
