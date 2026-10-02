// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "UploadFoundation", platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "UploadFoundation", targets: ["UploadFoundation"])],
    dependencies: [.package(path: "../HealthClient")],
    targets: [
        .target(name: "UploadFoundation", dependencies: [.product(name: "HealthClient", package: "HealthClient")]),
        .testTarget(name: "UploadFoundationTests", dependencies: ["UploadFoundation"])
    ]
)
