// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "BackupEngine", platforms: [.iOS(.v17), .macOS(.v13)],
 products: [.library(name: "BackupEngine", targets: ["BackupEngine"])],
 dependencies: [.package(path:"../MediaPreservation"),.package(path: "../UploadFoundation"), .package(path: "../PhotoDiscovery")],
 targets: [.systemLibrary(name: "CBackupSQLite", pkgConfig: "sqlite3"),
 .target(name: "BackupEngine", dependencies: ["MediaPreservation","CBackupSQLite", .product(name: "UploadFoundation", package: "UploadFoundation"), .product(name: "DiscoveryCore", package: "PhotoDiscovery")]),
 .testTarget(name: "BackupEngineTests", dependencies: ["BackupEngine"])])
