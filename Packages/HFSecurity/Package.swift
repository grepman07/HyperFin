// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HFSecurity",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "HFSecurity", targets: ["HFSecurity"]),
    ],
    dependencies: [
        .package(path: "../HFShared"),
    ],
    targets: [
        .target(name: "HFSecurity", dependencies: ["HFShared"]),
        .testTarget(name: "HFSecurityTests", dependencies: ["HFSecurity"]),
    ]
)
