// swift-tools-version:5.9
//
// SwiftPM package for the @objc wrapper that re-exports DVAIBridge.shared's
// API surface as Obj-C-callable methods. The actual xcframework is built
// from this target via build-xcframework.sh (see ./build-xcframework.sh)
// and bundled inside the DVAIBridge.iOS NuGet at pack time.
//
// Depends on the Phase 3C iOS umbrella `DVAIBridge` SwiftPM target via a
// path-based dep so CI macos-latest runners (which check out the monorepo)
// can resolve without external network access.
//
// iOS deployment target: 15.1 — matches the Phase 3C umbrella's floor.

import PackageDescription

let package = Package(
    name: "DVAIBridgeNetBridge",
    platforms: [
        .iOS(.v15),
        .macCatalyst(.v15)
    ],
    products: [
        .library(
            name: "DVAIBridgeNetBridge",
            type: .static,
            targets: ["DVAIBridgeNetBridge"]
        )
    ],
    dependencies: [
        // Path-based: the monorepo's iOS umbrella lives at
        // packages/dvai-bridge-ios relative to the repo root.
        .package(name: "DVAIBridge", path: "../../../../dvai-bridge-ios")
    ],
    targets: [
        .target(
            name: "DVAIBridgeNetBridge",
            dependencies: [
                .product(name: "DVAIBridge", package: "DVAIBridge")
            ]
        )
    ]
)
