// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DVAICapacitorLlama",
    platforms: [.iOS(.v14), .macOS(.v12)],
    products: [
        .library(name: "DVAICapacitorLlama", targets: ["DVAICapacitorLlama"]),
    ],
    dependencies: [
        // Capacitor SPM artifact (existing)
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm", branch: "main"),
        // Core package — relative path during dev, replaced with version-pin
        // or git URL at publish time. The path is relative to *this* Package.swift's
        // location (`packages/dvai-bridge-capacitor-llama/ios/`), so two `..` get
        // us to the `packages/` parent and `dvai-bridge-ios-llama-core/ios` is the
        // sibling package's SPM root.
        .package(name: "DVAILlamaCore", path: "../../dvai-bridge-ios-llama-core/ios"),
    ],
    targets: [
        .target(
            name: "DVAICapacitorLlama",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm"),
                .product(name: "DVAILlamaCore", package: "DVAILlamaCore"),
            ],
            path: "Sources/DVAICapacitorLlama",
            exclude: ["PluginProxy.m"]
        ),
        .testTarget(
            name: "DVAICapacitorLlamaTests",
            dependencies: ["DVAICapacitorLlama"],
            path: "Tests/DVAICapacitorLlamaTests"
        ),
    ]
)
