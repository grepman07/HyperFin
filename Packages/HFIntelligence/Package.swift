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
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "2.30.6"),
    ],
    targets: [
        .target(
            name: "HFIntelligence",
            dependencies: [
                "HFDomain",
                "HFShared",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ]
        ),
        .testTarget(name: "HFIntelligenceTests", dependencies: ["HFIntelligence"]),
    ]
)
