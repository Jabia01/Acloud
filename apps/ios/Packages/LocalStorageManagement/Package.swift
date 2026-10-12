// swift-tools-version: 5.9
import PackageDescription
let package=Package(name:"LocalStorageManagement",platforms:[.iOS(.v17),.macOS(.v13)],products:[.library(name:"LocalStorageManagement",targets:["LocalStorageManagement"])],dependencies:[.package(path:"../BackupEngine"),.package(path:"../MediaPreservation")],targets:[.systemLibrary(name:"CCleanupSQLite",pkgConfig:"sqlite3"),.target(name:"LocalStorageManagement",dependencies:["CCleanupSQLite","BackupEngine","MediaPreservation"]),.testTarget(name:"LocalStorageManagementTests",dependencies:["LocalStorageManagement","BackupEngine"])])
