// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PhotoDiscovery",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "DiscoveryCore", targets: ["DiscoveryCore"]),
        .library(name: "PhotoKitDiscovery", targets: ["PhotoKitDiscovery"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "DiscoveryCore", dependencies: ["CSQLite"]),
        .target(name: "PhotoKitDiscovery", dependencies: ["DiscoveryCore"]),
        .testTarget(name: "DiscoveryCoreTests", dependencies: ["DiscoveryCore"])
    ]
)
