// swift-tools-version: 5.9
import PackageDescription

// Capacitor plugin for LiteRT-LM. Dual-platform: Android via
// android-litert-core, iOS/macOS via dvai-bridge-ios-litertlm-core.
// (Unlike capacitor-mediapipe, which is Android-only.)
let package = Package(
    name: "DVAICapacitorLiteRTLM",
    // iOS 17 / macOS 14 — matches dvai-bridge-ios-litertlm-core's floor
    // (which itself inherits from DVAISharedCore / Hummingbird 2.x).
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DVAICapacitorLiteRTLM", targets: ["DVAICapacitorLiteRTLM"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm", branch: "main"),
        // Path relative to this manifest at packages/dvai-bridge-capacitor-litertlm/ios/.
        // Two `..` reaches packages/, dvai-bridge-ios-litertlm-core is the sibling.
        // The core Package.swift lives at the package root (not under ios/) so
        // SPM derives identity "dvai-bridge-ios-litertlm-core" — same trick used
        // by capacitor-llama.
        .package(path: "../../dvai-bridge-ios-litertlm-core"),
    ],
    targets: [
        .target(
            name: "DVAICapacitorLiteRTLM",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm"),
                .product(name: "DVAILiteRTLMCore", package: "dvai-bridge-ios-litertlm-core"),
            ],
            path: "Sources/DVAICapacitorLiteRTLM",
            exclude: ["PluginProxy.m"]
        ),
        .testTarget(
            name: "DVAICapacitorLiteRTLMTests",
            dependencies: [
                "DVAICapacitorLiteRTLM",
                .product(name: "DVAILiteRTLMCore", package: "dvai-bridge-ios-litertlm-core"),
            ],
            path: "Tests/DVAICapacitorLiteRTLMTests"
        ),
    ]
)
