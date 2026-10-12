# Native privacy review — 12 October 2026

Engineering preparation for the private staging client at native checkpoint 5b814f8. This is not a published policy, completed Apple questionnaire or legal approval. App Store Connect has not been changed.

## Manifest scope

`apps/ios/PrivacyInfo.xcprivacy` is included in the application resources through project.yml. All Swift packages are first-party local packages linked into the app. No third-party advertising, attribution, analytics or crash SDK was found in the native package/project inventory. The manifest reports no tracking and no tracking domains. The staging API and B2 host are service endpoints, not tracking domains.

The source review identifies two covered API categories:

| Category | Reason | Implementation and limits |
| --- | --- | --- |
| UserDefaults | CA92.1 | AccountView, BackupQueueView, RestoreView and StorageView persist app-owned random device/library identifiers in the app's standard defaults. No other-app defaults, app-group domain or MDM configuration is accessed. Authentication secrets use Keychain. |
| DiskSpace | E174.1 | RestoreEngine SystemDeviceCapacity reads volumeAvailableCapacityForImportantUsageKey. Ordinary and compound restore coordinators pause with DEVICE_SPACE_REQUIRED before downloads when capacity is insufficient. Space values stay local; there is no disk-space telemetry payload. |

No direct system-uptime, active-keyboard or covered filesystem timestamp API was found in shipping Swift source. PHAsset.creationDate/modificationDate describe chosen Photos media; they are distinct from FileManager/URL filesystem timestamp APIs. File size and regular-file checks occur in app-owned temporary/state files. Do not add an unrelated file timestamp reason solely because Photos has a date property. Reassess the linked binary and future dependencies before distribution; source searches do not certify every system implementation detail.

Apple's [required-reason API categories](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype) and [reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons) were checked on 12 October. The selected reasons follow the observed app behavior, not an SDK-wrapper exemption.

## Data collection worksheet

The manifest includes these app-functionality categories, linked to the account/device and not used for tracking. Account association persists on the server; hashes and UUIDs do not establish anonymity. This worksheet is the proposed App Store answer set, subject to final artifact/provider and operator review.

| Apple category | Evidence and purpose |
| --- | --- |
| Email Address | Native register/login; users email and normalized address; account access and transactional messages. |
| User ID | Authenticated account/session associations, ownership checks and audit history. |
| Device ID | App-generated device identifier, authenticated server device ID and library binding for safe backup/restore. This is not IDFA or a hardware identifier. |
| Photos or Videos | Explicitly selected original bytes stored privately for backup/restore. Media shape, dates, sizes, content hashes and version evidence support preservation/integrity. |
| Audio Data | Conservative disclosure for sound retained within original video backups. No microphone capture permission or separate recording feature is introduced. |
| Precise Location | Conservative disclosure because original files can retain GPS metadata. No Core Location API or live-location permission is used; this is embedded media metadata, not continuous device tracking. Do not state that original-media backup excludes location. |
| Other Data Types | Password verifiers, authentication/security state, OS/app versions and preservation/integrity metadata not otherwise represented above. Raw passwords are transmitted for authentication and are not intended to be retained or logged. |
| Performance Data | Server request timings and optional restore durations support reliability. Some restore events are account-linked, so the declaration does not claim all timings anonymous. |
| Other Diagnostic Data | Account-associated restore result/retry codes and security/audit events, with bounded codes rather than media content. |

Audio/location are disclosed conservatively for preserved originals; they are not extracted for profiling or used for a different purpose. Revisit classification with the actual submission reviewer rather than silently remove them to make a shorter label. User photos may contain sensitive information about the user or other people. Further classification is required if Acloud adds health/sensitive-data extraction or a specific sensitive-content workflow; this review does not infer that from arbitrary picture contents.

No native billing, ads, browsing/search history, contacts, camera capture, standalone microphone recording or behavioral analytics SDK is evidenced in this scoped version. Apple TestFlight diagnostics/feedback, future support forms and infrastructure-provider logging need the final distribution/provider inventory; do not infer they collect nothing from the absence of a native SDK. Privacy answers must change when functionality or collection changes.

Apple's [data types and collection guidance](https://developer.apple.com/app-store/app-privacy-details/) and [manifest data type values](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatype) informed the mapping. A privacy manifest and App Store privacy answers are separate from a published privacy notice.

## Current service inventory

Known staging topology: Railway API/worker, Supabase PostgreSQL, private Backblaze B2 media storage, Resend transactional email and Vercel web. The B2 configured endpoint is EU Central; an endpoint name alone does not establish all data locations or legal transfer safeguards. Confirm account regions, provider log/backup destinations, access policies, DPAs and retention before publishing a location promise. No claim of Nigerian-only storage or end-to-end encryption is made. Server processes verify content; authorized infrastructure can access stored data.

## Decisions before publication/submission

- Legal operator/controller name and working privacy contact.
- Final notice URL and support route; the web privacy request page is not itself a published policy.
- Approved retention periods for active/closed account records, media versions, incomplete transfers, infrastructure backups, auth capabilities, security/audit records, diagnostics and support. Distinguish access revocation from physical deletion and expiring backup copies.
- Provider account/region/contract and onward-transfer inventory, actual staff access and recovery processes.
- Supported initial audience/geography and treatment of children's/sensitive media, reviewed by the operator and appropriate adviser.
- Actual archive privacy report and Apple processing validation after signing becomes available. No paid Apple Developer membership is currently held by the user.

A concrete draft notice is in BETA_PRIVACY_NOTICE_DRAFT.md. It remains clearly marked DRAFT with unresolved fields rather than invented identities, deadlines or deletion promises. Customer cleanup, payments, broad admission and hosted interruption testing are not enabled by this privacy work.

## Validation completed

- Manifest plist lint passed; nine distinct data categories and two reason categories checked.
- Official XcodeGen 2.46.0 used temporarily (release ZIP SHA-256 `4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806`) to generate from committed native files plus this change. No replacement of the working device project.
- Fresh generic-device unsigned Release build succeeded. A development bundle identifier override was used only to compile without signing; this output is not distributable.
- Built PrivacyInfo.xcprivacy equals the source manifest (source SHA-256 `de03e40503cdb239045d2c2fdf0c6821fb23fe06948c87dee62e805ab537916a`).
- Built Info.plist has BetaRelease=true; cleanup/disposable/background development flags=false; arbitrary/local networking exceptions=false; no local-network usage description. The initial fresh-generation failure selected the development plist due to target-setting precedence; moving the Release plist override to the target fixed it.
- Five release-safety tests passed, including rejection of an archive missing its privacy manifest and an unsigned archive with a valid manifest.

No Swift runtime implementation changed, so the seven native package suites were not repeated after the preceding 336-test checkpoint. Apple archive processing, generated privacy-report review and signed/TestFlight acceptance remain unavailable until signing/membership and Release inputs are supplied. No data deletion, deployment, publication or privacy portal submission occurred.
