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
        // Telegraph: same HTTP server stack as the other *-core packages.
        .package(url: "https://github.com/Building42/Telegraph.git", from: "0.40.0"),
        // DVAILlamaCore for shared HandlerContext / DVAIHandlers / HttpServer
        // / port-fallback / CORS plumbing. We wire MLXHandlers into the same
        // server pattern the other backends use.
        .package(path: "../dvai-bridge-ios-llama-core"),
    ],
    targets: [
        .target(
            name: "DVAIMLXCore",
            dependencies: [
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "DVAILlamaCore", package: "dvai-bridge-ios-llama-core"),
                "Telegraph",
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
