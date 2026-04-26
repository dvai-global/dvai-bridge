// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DVAIBridge",
    platforms: [.iOS(.v14), .macOS(.v12)],
    products: [
        .library(name: "DVAIBridge", targets: ["DVAIBridge"]),
        .library(name: "DVAICoreMLCore", targets: ["DVAICoreMLCore"]),
    ],
    dependencies: [
        // Path-dep to the cores. Identity is derived from the path's last
        // directory name; both cores have manifests at their package root,
        // so identities are `dvai-bridge-ios-llama-core` and
        // `dvai-bridge-ios-foundation-core`.
        .package(path: "../dvai-bridge-ios-llama-core"),
        .package(path: "../dvai-bridge-ios-foundation-core"),
    ],
    targets: [
        .target(
            name: "DVAICoreMLCore",
            path: "ios/Sources/DVAICoreMLCore"
        ),
        .target(
            name: "DVAIBridge",
            dependencies: [
                .product(name: "DVAILlamaCore", package: "dvai-bridge-ios-llama-core"),
                .product(name: "DVAIFoundationCore", package: "dvai-bridge-ios-foundation-core"),
                "DVAICoreMLCore",
            ],
            path: "ios/Sources/DVAIBridge"
        ),
        .testTarget(
            name: "DVAIBridgeTests",
            dependencies: [
                "DVAIBridge",
                .product(name: "DVAILlamaCore", package: "dvai-bridge-ios-llama-core"),
                .product(name: "DVAIFoundationCore", package: "dvai-bridge-ios-foundation-core"),
                "DVAICoreMLCore",
            ],
            path: "ios/Tests/DVAIBridgeTests"
        ),
    ]
)
