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
        // v4.2.3: Dropped .macCatalyst("18.1"). LiteRT-LM (added to the
        // iOS umbrella in v4.2.1) transitively links CLiteRTLM.xcframework
        // which ships only ios-arm64 + ios-arm64-simulator — no Catalyst
        // slice. Restoring Catalyst requires either an upstream Catalyst
        // slice for LiteRT-LM, or splitting the iOS umbrella so this
        // binding can opt out of LiteRT-LM (planned for v4.3.0).
        .iOS("18.1")
    ],
    products: [
        // type: .dynamic — `BUILD_LIBRARY_FOR_DISTRIBUTION=NO` (needed to
        // sidestep swift-certificates #254) only emits a packaged
        // `.framework` bundle when the library is dynamic; with `.static`
        // we'd get loose `.o` files in the .xcarchive Products dir, which
        // `xcodebuild -create-xcframework -framework ...` can't consume.
        // The .NET binding's <NativeReference> in DVAIBridge.iOS.csproj
        // links the resulting framework via the Xamarin/Mono runtime —
        // works with both static and dynamic frameworks, so the dynamic
        // form here doesn't change the consumer surface.
        .library(
            name: "DVAIBridgeNetBridge",
            type: .dynamic,
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
