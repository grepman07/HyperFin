// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HFIntelligence",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "HFIntelligence", targets: ["HFIntelligence"]),
    ],
    dependencies: [
        .package(path: "../HFDomain"),
        .package(path: "../HFShared"),
    ],
    targets: [
        .target(name: "HFIntelligence", dependencies: ["HFDomain", "HFShared"]),
        .testTarget(name: "HFIntelligenceTests", dependencies: ["HFIntelligence"]),
    ]
)
