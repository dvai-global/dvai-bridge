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
        // directory name; each core has its manifest at the package root,
        // so identities are `dvai-bridge-ios-shared-core` /
        // `dvai-bridge-ios-llama-core` / `dvai-bridge-ios-foundation-core` /
        // `dvai-bridge-ios-mlx-core`.
        .package(path: "../dvai-bridge-ios-shared-core"),
        .package(path: "../dvai-bridge-ios-llama-core"),
        .package(path: "../dvai-bridge-ios-foundation-core"),
        .package(path: "../dvai-bridge-ios-mlx-core"),
        // swift-transformers 1.3.0 (latest stable as of 2026-04-26).
        // Provides Tokenizers product for HuggingFace tokenizer loading.
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.0"),
        // Telegraph HTTP server — transitively used by shared-core; we pull
        // it directly for DVAICoreMLCore so the target's link line is
        // self-explanatory.
        .package(url: "https://github.com/Building42/Telegraph.git", from: "0.40.0"),
    ],
    targets: [
        .target(
            name: "DVAICoreMLCore",
            dependencies: [
                .product(name: "Tokenizers", package: "swift-transformers"),
                "Telegraph",
                // CoreML backend uses shared HTTP types — DOES NOT depend on
                // DVAILlamaCore (so CoreML-only consumers don't transitively
                // pull llama.xcframework).
                .product(name: "DVAISharedCore", package: "dvai-bridge-ios-shared-core"),
            ],
            path: "ios/Sources/DVAICoreMLCore"
        ),
        .target(
            name: "DVAIBridge",
            dependencies: [
                // DVAIBridge depends on all four backends + shared types.
                // The llama-core dep is what brings in ModelDownloader; if a
                // future refactor extracts that too, DVAIBridge could drop
                // the llama-core dep when the consumer is using only
                // .mlx / .foundation / .coreml.
                .product(name: "DVAISharedCore", package: "dvai-bridge-ios-shared-core"),
                .product(name: "DVAILlamaCore", package: "dvai-bridge-ios-llama-core"),
                .product(name: "DVAIFoundationCore", package: "dvai-bridge-ios-foundation-core"),
                .product(name: "DVAIMLXCore", package: "dvai-bridge-ios-mlx-core"),
                "DVAICoreMLCore",
            ],
            path: "ios/Sources/DVAIBridge"
        ),
        .testTarget(
            name: "DVAIBridgeTests",
            dependencies: [
                "DVAIBridge",
                .product(name: "DVAISharedCore", package: "dvai-bridge-ios-shared-core"),
                .product(name: "DVAILlamaCore", package: "dvai-bridge-ios-llama-core"),
                .product(name: "DVAIFoundationCore", package: "dvai-bridge-ios-foundation-core"),
                .product(name: "DVAIMLXCore", package: "dvai-bridge-ios-mlx-core"),
                "DVAICoreMLCore",
            ],
            path: "ios/Tests/DVAIBridgeTests"
        ),
    ]
)
