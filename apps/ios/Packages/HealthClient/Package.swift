// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HealthClient",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "HealthClient", targets: ["HealthClient"])],
    targets: [
        .target(name: "HealthClient"),
        .testTarget(name: "HealthClientTests", dependencies: ["HealthClient"])
    ]
)
