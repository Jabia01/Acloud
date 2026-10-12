// swift-tools-version: 5.9
import PackageDescription
let package=Package(name:"MediaPreservation",platforms:[.iOS(.v17),.macOS(.v13)],products:[.library(name:"MediaPreservation",targets:["MediaPreservation"])],targets:[.systemLibrary(name:"CMediaSQLite",pkgConfig:"sqlite3"),.target(name:"MediaPreservation",dependencies:["CMediaSQLite"]),.testTarget(name:"MediaPreservationTests",dependencies:["MediaPreservation"])])
