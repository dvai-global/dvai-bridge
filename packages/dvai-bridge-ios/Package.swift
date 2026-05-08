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
        // swift-transformers — provides Tokenizers product for HuggingFace
        // tokenizer loading. Constraint relaxed to `from: 1.2.0` to keep
        // our resolver compatible with mlx-swift-lm 2.x (which pins
        // swift-transformers `<1.3.0`). Our usage of AutoTokenizer.from(modelFolder:)
        // / applyChatTemplate / encode / decode is API-compatible across
        // 1.2.x → 1.3.x.
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.2.0"),
        // v3.2.0 — Hummingbird is the iOS HTTP server backbone (replaces
        // Telegraph). DVAISharedCore exports it transitively via its
        // HttpServer actor, but we pull it here too so the OffloadProxy
        // can use it directly without a `@_implementationOnly` import
        // gymnastics step.
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "DVAICoreMLCore",
            dependencies: [
                .product(name: "Tokenizers", package: "swift-transformers"),
                // CoreML backend uses shared HTTP types — DOES NOT depend on
                // DVAILlamaCore (so CoreML-only consumers don't transitively
                // pull llama.xcframework). DVAISharedCore brings Hummingbird
                // transitively as of v3.2.0.
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
                // v3.2 Phase 5 — outgoing-offload pre-routing proxy.
                // Hummingbird (built on swift-nio) gives us proper
                // streaming SSE bodies through the proxy.
                .product(name: "Hummingbird", package: "hummingbird"),
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
