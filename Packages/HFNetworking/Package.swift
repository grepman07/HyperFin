// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HFNetworking",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "HFNetworking", targets: ["HFNetworking"]),
    ],
    dependencies: [
        .package(path: "../HFDomain"),
        .package(path: "../HFShared"),
    ],
    targets: [
        .target(name: "HFNetworking", dependencies: ["HFDomain", "HFShared"]),
        .testTarget(name: "HFNetworkingTests", dependencies: ["HFNetworking"]),
    ]
)
