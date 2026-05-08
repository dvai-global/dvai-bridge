// swift-tools-version: 5.9
import PackageDescription

// MLX runs on Apple Silicon GPU/Neural Engine via Apple's MLX Swift framework.
// Platform floor: iOS 17 / macOS 14 (mlx-swift-lm's own minimum).
// Runtime requirement: Apple Silicon (no Intel Mac, no iOS Simulator on
// Intel hosts). The library compiles and links on Intel sims but `MLX.GPU`
// always reports unavailable, so any `start()` call returns a clear error.
let package = Package(
    name: "DVAIMLXCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DVAIMLXCore", targets: ["DVAIMLXCore"]),
    ],
    dependencies: [
        // mlx-swift-lm bundles MLXLLM (LLM inference) + MLXLMCommon
        // (ChatSession, ModelContainer) and pulls mlx-swift + swift-
        // transformers transitively. We pin to 2.31.x because its
        // `loadModelContainer(id:)` convenience API (HuggingFace Hub-
        // backed) is the simplest path to a working model load. The
        // 3.x line introduced an explicit Downloader + TokenizerLoader
        // requirement that would force us to build a HF download/auth
        // story alongside this scaffold; defer to Phase 3D.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", "2.31.3" ..< "3.0.0"),
        // Shared HTTP-server / handler-dispatch types. Note: previously
        // depended on DVAILlamaCore for these types, but that transitively
        // pulled the llama.xcframework into MLX-only builds. The
        // shared-core extraction breaks that coupling so MLX consumers
        // don't drag a binary they never use. DVAISharedCore brings in
        // Hummingbird transitively as of v3.2.0 — the iOS HTTP server
        // backbone is no longer Telegraph.
        .package(path: "../dvai-bridge-ios-shared-core"),
    ],
    targets: [
        .target(
            name: "DVAIMLXCore",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "DVAISharedCore", package: "dvai-bridge-ios-shared-core"),
            ],
            path: "ios/Sources/DVAIMLXCore"
        ),
        .testTarget(
            name: "DVAIMLXCoreTests",
            dependencies: ["DVAIMLXCore"],
            path: "ios/Tests/DVAIMLXCoreTests"
        ),
    ]
)
