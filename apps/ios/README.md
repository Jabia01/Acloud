# iOS foundation

Native SwiftUI, iOS 17+, with ACL-002 account screens, Keychain-backed
authentication and ACL-003 local PhotoKit discovery. ACL-004 adds a separate
generated-file upload architecture package; no automatic PhotoKit upload or payments.
The networking package is independent of display branding. `project.yml` is the
version-controlled XcodeGen project source; generated Xcode projects and signing
state are ignored to avoid committing machine-specific state.

On a Mac with Xcode and XcodeGen (`brew install xcodegen`):

```sh
cd apps/ios
xcodegen generate
open BackupClient.xcodeproj
```

Select the BackupClient scheme and an iPhone simulator, then Run. Start the API
and database on the same Mac first. The simulator uses `http://localhost:3001`.
The app displays the configured product name, Development Build,
API Status: Checking..., Connected or Unavailable, and basic Sign In,
Create Account and Signed In/Account Status forms. Connected requires a
healthy API **and** database. Relaunch to repeat the check.

For a physical iPhone, set Debug's API_BASE_URL in `project.yml` to the Mac's
local hostname (`http://your-mac.local:3001`), regenerate, choose your signing
team in Xcode, and use the same trusted Wi-Fi network. Permit the macOS firewall
connection as needed. Docker ports bind to loopback; run the API on the host for
device testing. Access to the local network may require an iOS local-network
consent prompt; it is unrelated to photo permissions. The project configuration
includes a local-network usage description for this purpose. Do not use customer data.

App Transport Security permits local networking only; there is no global
arbitrary HTTP exception. Release uses an intentionally nonfunctional HTTPS
placeholder and is not a production configuration. Review ATS and signing
before any distribution; do not ship this development build.

Networking tests:

```sh
cd Packages/HealthClient
swift test
```

Compile for simulator without signing (after generation, from apps/ios):

```sh
xcodebuild -project BackupClient.xcodeproj -scheme BackupClient -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Windows cannot run Xcode or the iOS simulator. The scaffold must be built and
its XCTest suite run on macOS before it is considered validated.

ACL-003 adds Photos, Account and Development tabs. Photos asks for access only
after Allow Photo Access, distinguishes all five authorization states, offers
Apple's limited picker/Settings, shows counts, known/unknown sizes, progress,
cancellation and resume. Metadata is persisted in a protected, backup-excluded
SQLite database, never sent to the backend. The default iOS 17 build reports
resource sizes unknown. See [discovery architecture](../../docs/PHOTO_LIBRARY_DISCOVERY.md)
and [macOS/device validation](../../docs/IOS_VALIDATION_PLAN.md).

Discovery tests (24 authored, unexecuted on Windows):

```sh
cd apps/ios/Packages/PhotoDiscovery # from repository root
swift test
```

The optional `PHOTOKIT_RESOURCE_SIZE_METADATA` compilation condition requires
an SDK declaring the iOS 27 public `PHAssetResource.dataSize` property. Leave it
unset on older SDKs. Runtime availability is checked; no private size API or
content download fallback exists. Verify that optional configuration on a Mac
before enabling it. CI now includes discovery tests; it has not run in this task.

ACL-004 UploadFoundation provides UploadCoordinator, UploadSessionClient,
SinglePartUploadTransport and a bounded atomic FileUploadStateStore. It uses
explicitly supplied generated files inside a fixture directory (≤5 MiB), reuses
Keychain-backed API sessions, transfers directly without an API bearer/cookies,
handles cancellation/lost responses by stable keys, and accepts protection only
from server-verified asset state. No discovery view calls the upload coordinator.
No native upload UI or automatic originals retrieval is added. The package is
linked in project.yml so the next native app build must compile it.

```sh
cd apps/ios/Packages/UploadFoundation # from repository root
swift test
```

17 new generated/mock XCTest cases are authored and **unexecuted here**. The user
reported earlier Mac HealthClient 11/11, PhotoDiscovery 24/24 and simulator
discovery success; that does not validate the new upload package or a real iPhone.
Physical iPhone PhotoKit upload integration remains UNVALIDATED. See the upload
sections of [native plan](../../docs/IOS_VALIDATION_PLAN.md) and
[upload lifecycle](../../docs/UPLOAD_LIFECYCLE.md). Do not use customer media.

ACL-002 adds AuthAPI (register/login/logout/me), a SessionTokenStore interface,
KeychainSessionStore and memory-store network tests. Keychain uses
WhenUnlockedThisDeviceOnly and excludes iCloud synchronization. The only
UserDefaults value is a non-secret client-generated device identifier. No
auth token is displayed or persisted outside Keychain. Authenticated 401 clears
the token. Failed network logout retains it for retry; it never claims successful
server revocation. The default URLSession is ephemeral and rejects redirects.

Run all 11 authored XCTest cases on macOS: five health cases, five auth network
cases and one Keychain roundtrip case. Also validate real simulator registration,
login, relaunch/session restoration, logout, 401 after web device revocation,
locked-device Keychain behavior and rejected remote HTTP configuration. Windows
execution does not validate those behaviors. Review signing/keychain entitlements
for simulator and device tests. Verification/reset links use the local website
and Mailpit; native recovery forms are not part of this scaffold.
