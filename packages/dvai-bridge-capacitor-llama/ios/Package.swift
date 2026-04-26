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
        // The core's Package.swift lives at the PACKAGE ROOT (not under `ios/`)
        // so that SPM derives identity "dvai-bridge-ios-llama-core" rather than
        // "ios" for this dependency. With both Package.swifts at `ios/`, SPM's
        // path-dep identity-from-last-dir-name rule aliased them and triggered
        // a false `cyclic dependency between packages DVAICapacitorLlama ->
        // DVAICapacitorLlama` resolution error. The bare product reference
        // ("DVAILlamaCore") in the target dependency list below works because
        // SPM auto-resolves unambiguous product names across the dep graph.
        .package(path: "../../dvai-bridge-ios-llama-core"),
    ],
    targets: [
        .target(
            name: "DVAICapacitorLlama",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm"),
                // The package's identity is derived from the last dir of the
                // path dep (`dvai-bridge-ios-llama-core`), not from the
                // manifest's `name:` field. Bare-name product references don't
                // cross package boundaries reliably; explicit form is required.
                .product(name: "DVAILlamaCore", package: "dvai-bridge-ios-llama-core"),
            ],
            path: "Sources/DVAICapacitorLlama",
            exclude: ["PluginProxy.m"]
        ),
        .testTarget(
            name: "DVAICapacitorLlamaTests",
            dependencies: [
                "DVAICapacitorLlama",
                // RealModelSmokeTest reaches the core directly (LlamaCppBridge,
                // ModelDownloader, MTMD_MEDIA_MARKER) — declare both core products
                // explicitly so Xcode resolves them at link time.
                .product(name: "DVAILlamaCore", package: "dvai-bridge-ios-llama-core"),
                .product(name: "DVAILlamaCoreObjC", package: "dvai-bridge-ios-llama-core"),
            ],
            path: "Tests/DVAICapacitorLlamaTests"
        ),
    ]
)
