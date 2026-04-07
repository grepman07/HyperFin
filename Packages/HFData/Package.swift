// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HFData",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "HFData", targets: ["HFData"]),
    ],
    dependencies: [
        .package(path: "../HFDomain"),
        .package(path: "../HFSecurity"),
        .package(path: "../HFShared"),
    ],
    targets: [
        .target(name: "HFData", dependencies: ["HFDomain", "HFSecurity", "HFShared"]),
        .testTarget(name: "HFDataTests", dependencies: ["HFData"]),
    ]
)
