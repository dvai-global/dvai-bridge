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
// iOS deployment target: 18.1 — matches the Phase 3C umbrella's floor
// (.iOS("18.1") declared in dvai-bridge-ios/Package.swift; lower values
// here previously caused llama.cpp Metal shaders to be compiled against
// an iOS 15.1 SDK that lacks `bfloat16_t`, producing cascading
// `unknown type name 'bfloat'` + `redefinition of 'abs'` errors).

import PackageDescription

let package = Package(
    name: "DVAIBridgeNetBridge",
    platforms: [
        .iOS("18.1"),
        .macCatalyst("18.1")
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
        .package(name: "DVAIBridge", path: "../../../../dvai-bridge-ios"),
        // Pin swift-certificates to 1.18.0 because 1.19.x has Swift
        // strict-init regressions in `_CertificateInternals/_TinyArray.swift`
        // (`'self.init' isn't called on all paths` + `'self' used before
        // 'self.init'`) that block xcodebuild archive under the current
        // macos-latest Xcode toolchain. Declared here even though we
        // don't import swift-certificates directly — jwt-kit pulls it
        // transitively, and SwiftPM resolves a single global version
        // across the dep graph, so this `exact` constraint forces the
        // good version everywhere. Remove once upstream 1.20.x ships
        // with the fix.
        .package(url: "https://github.com/apple/swift-certificates.git", exact: "1.18.0")
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
