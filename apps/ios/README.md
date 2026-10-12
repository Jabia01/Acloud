# Native iOS client

SwiftUI client for iOS 17+, with Keychain-backed account sessions, local PhotoKit discovery, explicit media selection, persistent backup/restore queues, integrity verification and gated storage management. Discovery does not automatically upload media. Originals are retained; customer cleanup is disabled in the current configuration. No storage credentials belong in this app.

## Project and configuration

`project.yml` is the XcodeGen source. Generated Xcode projects, local signing state and build products are ignored. All seven Swift packages are local dependencies under `Packages/`; no external package checkout is needed for these targets.

On a Mac with Xcode and XcodeGen installed:

```sh
cd apps/ios
xcodegen generate
open BackupClient.xcodeproj
```

Debug defaults to the hosted staging API and B2 origin configured in `project.yml`. For an explicitly authorized local test, change the Debug origins to the intended Mac service before generation. Device installation requires selecting your own signing team in Xcode. Regeneration can replace manual Xcode settings, so retain needed local signing overrides separately.

Release uses `Configuration/Beta.xcconfig` and `Configuration/Info-Beta.plist`. Bundle ID, team, API/storage origins and deployment fingerprint deliberately remain blank until reviewed. Release rejects incomplete configuration and requires server admission for real-media flows. It excludes the Development tab and generated-upload controls and disables disposable cleanup and development background transfers. A successful unsigned compilation does not make this a distributable build.

## Validation

Run each package's tests from the repository root:

```sh
swift test --package-path apps/ios/Packages/HealthClient
swift test --package-path apps/ios/Packages/PhotoDiscovery
swift test --package-path apps/ios/Packages/UploadFoundation
swift test --package-path apps/ios/Packages/BackupEngine
swift test --package-path apps/ios/Packages/MediaPreservation
swift test --package-path apps/ios/Packages/RestoreEngine
swift test --package-path apps/ios/Packages/LocalStorageManagement
node --test scripts/test/beta-release.test.mjs
```

After generation, compile Debug without signing:

```sh
xcodebuild -project apps/ios/BackupClient.xcodeproj -scheme BackupClient -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

macOS package tests cannot establish PhotoKit behavior, iOS background execution, or physical device acceptance. Keep those results separate. Hosted ordinary iPad photo/video backup and restore were confirmed on 12 October 2026 in Debug; hosted interruption testing is pending by user choice. Earlier local interruption results remain historical acceptance, not fresh hosted results.

## Release status

Version 0.1.0/build 12. Draft icon exists but requires approval. A signed archive, reviewed privacy manifest/disclosures, Release admission and internal TestFlight acceptance remain pending. The user confirmed no paid Apple Developer membership on 12 October; enrollment is needed before TestFlight distribution. See [TestFlight preparation](../../docs/TESTFLIGHT_BETA.md) and [acceptance](../../docs/TESTFLIGHT_ACCEPTANCE.md).

Do not infer PROTECTED from uploaded bytes: only server verification grants protection. Authentication tokens use Keychain, not UserDefaults. Local library/device identifiers are non-secret metadata. Restore writes only explicitly selected verified items. Destructive operations require separate authorization and acceptance.
