// swift-tools-version: 5.9
import PackageDescription

// NOTE on iOS deployment target:
// `iOS("18.1")` here is the *link-time floor* — apps with an iOS 18.1+
// deployment target can install and link this package. The actual
// FoundationModels public API (`LanguageModelSession`, etc.) ships
// as `@available(iOS 26.0, *)` in the Xcode 26.4 SDK, so invoking
// the backend is gated *at runtime* on iOS 26.0+. On 18.1–25.x
// devices, `start()` rejects with a clear error and the handler
// class itself is `@available(iOS 26, *)` annotated.
//
// SwiftPM's `SupportedPlatform.IOSVersion` enum only got a `.v18`
// case in PackageDescription 6.0 (Swift 6 toolchain), and there is
// no `.v18_1` case at all. To stay on swift-tools-version 5.9 —
// matching the rest of the workspace — we use the string-based
// `.iOS(_:)` initializer, which accepts arbitrary version strings
// including "18.1". The podspec separately pins
// `s.ios.deployment_target = '18.1'` for app integration.
//
// macOS 14 covers the host-side `swift test` compile. The smoke test
// does not import FoundationModels, so the host build does not need
// iOS 18.1 / 26 availability.
let package = Package(
    name: "DVAICapacitorFoundation",
    platforms: [.iOS("18.1"), .macOS(.v14)],
    products: [
        .library(name: "DVAICapacitorFoundation", targets: ["DVAICapacitorFoundation"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Building42/Telegraph.git", from: "0.40.0"),
    ],
    targets: [
        // Swift target. The .m file (PluginProxy.m) is consumed by Capacitor
        // at app-build time via the podspec, not by SwiftPM directly — it is
        // excluded so SwiftPM does not try to compile mixed Swift/ObjC in
        // one target.
        .target(
            name: "DVAICapacitorFoundation",
            dependencies: ["Telegraph"],
            path: "Sources/DVAICapacitorFoundation",
            exclude: ["PluginProxy.m"]
        ),
        .testTarget(
            name: "DVAICapacitorFoundationTests",
            dependencies: ["DVAICapacitorFoundation"],
            path: "Tests/DVAICapacitorFoundationTests"
        ),
    ]
)
