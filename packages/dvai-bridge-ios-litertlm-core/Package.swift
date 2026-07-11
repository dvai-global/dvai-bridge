// swift-tools-version: 5.9
import PackageDescription

// LiteRT-LM (Google's on-device LLM runtime) via Swift SDK. Same runtime
// family as our Android `android-litert-core` — one .litertlm model file
// runs on both. Metal GPU acceleration on Apple Silicon; CPU fallback
// otherwise. Platform floor: iOS 17 / macOS 14 — matches DVAISharedCore
// (Hummingbird 2.x's own minimum). LiteRT-LM's own floor is iOS 16 /
// macOS 13, but DVAISharedCore's floor wins.
//
// SPM-only. Google does not ship CocoaPods for LiteRT-LM (yet). Consumers
// under the CocoaPods umbrella get a runtime `.backendUnavailable(.litertlm)`
// — same pattern as .mlx and .foundation. See docs/guide/ios-native-sdk.md
// "CocoaPods asymmetries" for the full list.
let package = Package(
    name: "DVAILiteRTLMCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DVAILiteRTLMCore", targets: ["DVAILiteRTLMCore"]),
    ],
    dependencies: [
        // LiteRT-LM Swift SDK.
        //
        // Pinned to v0.13.1's SHA (a0afb5a…) — NOT a version range —
        // for two reasons:
        //
        //  1. LiteRT-LM's own Package.swift uses `.unsafeFlags(
        //     ["-Xlinker", "-all_load"])` on the LiteRTLM target. SPM
        //     forbids `.unsafeFlags` in a *versioned* dependency chain
        //     ("target 'LiteRTLM' in product 'LiteRTLM' contains unsafe
        //     build flags"). Pinning to a revision instead of a version
        //     is the sanctioned escape hatch — SE-0292's rationale is
        //     specifically that revision-pins signal intentional trust.
        //
        //  2. v0.14.0 (2026-07-08) ships broken `checksum:` values in
        //     Package.swift for both xcframework binaryTargets — SPM
        //     aborts every resolve with `error: checksum of downloaded
        //     artifact ... does not match checksum specified by the
        //     manifest`. Filed upstream.
        //
        // Bump to v0.14.1's SHA once (a) upstream fixes the checksums
        // and, ideally, (b) removes the unsafeFlags so we can go back
        // to a proper version-range pin.
        .package(
            url: "https://github.com/google-ai-edge/LiteRT-LM.git",
            revision: "a0afb5a56acd106b23a2b2385b8469834dc268c0" // v0.13.1
        ),
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
