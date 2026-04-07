// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HFShared",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HFShared", targets: ["HFShared"]),
    ],
    targets: [
        .target(name: "HFShared"),
        .testTarget(name: "HFSharedTests", dependencies: ["HFShared"]),
    ]
)
