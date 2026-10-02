# ACL-003 review tree

```text
AGENTS.md                                      ACL-003 scope and media safety constraints
README.md                                      Current stage and native-validation links
.github/workflows/ci.yml                        Pending macOS discovery tests + existing app build
apps/ios/
  project.yml                                  PhotoDiscovery products + Photos usage keys
  README.md                                    Native build, tests and optional size configuration
  Sources/
    ContentView.swift                          Photos / Account / Development tabs
    DiscoveryView.swift                        Permissions, summary, task lifecycle, limited picker
    AccountView.swift                          Existing ACL-002 account screen (unchanged)
    BackupClientApp.swift                      Existing app entry point (unchanged)
  Packages/
    HealthClient/                              Existing networking/Keychain + 11 tests (unchanged)
    PhotoDiscovery/
      Package.swift                            Native SQLite + core + PhotoKit products
      Sources/
        CSQLite/{module.modulemap,shim.h}        SDK SQLite linkage
        DiscoveryCore/
          DiscoveryModels.swift                Local-only domain / nullable size policy
          DiscoveryInterfaces.swift            Provider, snapshot and store abstractions
          PhotoLibraryScanner.swift            Batched scan, cancellation, safe reconciliation
          SQLiteDiscoveredAssetStore.swift      Versioned schema 1, transactions and checkpoints
        PhotoKitDiscovery/
          PhotoKitLibrary.swift                PhotoKit permissions, snapshots, changes, size gate
          PhotoLibraryAccessUI.swift           iOS/UIKit picker adapter importing PhotosUI
      Tests/DiscoveryCoreTests/
        DiscoveryTests.swift                   24 authored tests; unexecuted on Windows
docs/
  PHOTO_LIBRARY_DISCOVERY.md                    Architecture, privacy, limitations, future identities
  IOS_VALIDATION_PLAN.md                        Exact pending macOS/device matrix
  VALIDATION.md                                Actual Windows results + native execution limitations
```

API/web/shared application code and both PostgreSQL migrations are unchanged by
ACL-003. Backend domain preparation is documentation only; no server media table
or metadata endpoint is added. No ACL-004 work, commit or push occurred.
