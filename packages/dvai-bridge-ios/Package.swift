// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DVAIBridge",
    // iOS 18.1 link-time floor: DVAIFoundationCore requires it (the
    // FoundationModels SDK is `@available(iOS 26, *)` at runtime; 18.1 is
    // its link-time minimum). DVAILlamaCore allows 14.0, but the package
    // as a whole takes the highest minimum. CoreML's MLState requires
    // iOS 18 too, so 18.1 covers everything.
    platforms: [.iOS("18.1"), .macOS(.v14)],
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
