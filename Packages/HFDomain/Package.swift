// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HFDomain",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "HFDomain", targets: ["HFDomain"]),
    ],
    dependencies: [
        .package(path: "../HFShared"),
    ],
    targets: [
        .target(name: "HFDomain", dependencies: ["HFShared"]),
        .testTarget(name: "HFDomainTests", dependencies: ["HFDomain"]),
    ]
)
