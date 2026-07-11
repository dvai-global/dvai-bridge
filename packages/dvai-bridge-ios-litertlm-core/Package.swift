// swift-tools-version: 5.9
import PackageDescription

// LiteRT-LM (Google's on-device LLM runtime) via Swift SDK. Same runtime
// family as our Android `android-litert-core` — one .litertlm model file
// runs on both. Metal GPU acceleration on Apple Silicon; CPU fallback
// otherwise. Platform floor: iOS 16 / macOS 13 (LiteRT-LM's own minimum).
//
// SPM-only. Google does not ship CocoaPods for LiteRT-LM (yet). Consumers
// under the CocoaPods umbrella get a runtime `.backendUnavailable(.litertlm)`
// — same pattern as .mlx and .foundation. See docs/guide/ios-native-sdk.md
// "CocoaPods asymmetries" for the full list.
let package = Package(
    name: "DVAILiteRTLMCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "DVAILiteRTLMCore", targets: ["DVAILiteRTLMCore"]),
    ],
    dependencies: [
        // LiteRT-LM Swift SDK. Pinned to 0.13.x — 0.12.0 was the first
        // release with the stable `Engine` + `Conversation.sendMessageStream`
        // API we wrap. Upper bound excludes 0.14.x because v0.14.0's
        // Package.swift manifest has stale `checksum:` values for its
        // CLiteRTLM / CLiteRTLM_mac xcframework binaryTargets — SPM aborts
        // the resolve with `error: checksum of downloaded artifact ...
        // does not match checksum specified by the manifest`. Bump the
        // upper bound once that lands fixed upstream.
        .package(url: "https://github.com/google-ai-edge/LiteRT-LM.git", "0.13.0" ..< "0.14.0"),
        // Shared HTTP-server / handler-dispatch types. Same reason as
        // DVAIMLXCore — avoids transitively pulling llama.xcframework
        // into consumers that only want LiteRT-LM.
        .package(path: "../dvai-bridge-ios-shared-core"),
    ],
    targets: [
        .target(
            name: "DVAILiteRTLMCore",
            dependencies: [
                .product(name: "LiteRTLM", package: "LiteRT-LM"),
                .product(name: "DVAISharedCore", package: "dvai-bridge-ios-shared-core"),
            ],
            path: "ios/Sources/DVAILiteRTLMCore"
        ),
        .testTarget(
            name: "DVAILiteRTLMCoreTests",
            dependencies: ["DVAILiteRTLMCore"],
            path: "ios/Tests/DVAILiteRTLMCoreTests"
        ),
    ]
)
