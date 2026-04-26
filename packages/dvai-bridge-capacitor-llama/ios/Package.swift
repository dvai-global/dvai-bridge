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
        //
        // We omit the `name:` parameter to dodge a SPM identity-disambiguation
        // edge case: both Package.swifts live at `ios/` subdirs, and the legacy
        // `.package(name:path:)` form trips a false `cyclic dependency between
        // packages DVAICapacitorLlama -> DVAICapacitorLlama` error under
        // tools-version 5.9. SPM derives the dependency's identity from the
        // manifest at the path; we reference the product by its bare name in
        // the target's dependencies below.
        .package(path: "../../dvai-bridge-ios-llama-core/ios"),
    ],
    targets: [
        .target(
            name: "DVAICapacitorLlama",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm"),
                "DVAILlamaCore",
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
