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
        // LiteRT-LM Swift SDK. Floor at 0.12.0 — first release with the
        // stable `Engine` + `Conversation.sendMessageStream` API we wrap.
        .package(url: "https://github.com/google-ai-edge/LiteRT-LM.git", "0.12.0" ..< "1.0.0"),
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
