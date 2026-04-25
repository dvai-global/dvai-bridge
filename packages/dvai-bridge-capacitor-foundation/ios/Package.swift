// swift-tools-version: 5.9
import PackageDescription

// NOTE on iOS deployment target:
// Apple Foundation Models requires iOS 18.1+ at runtime. SwiftPM's
// `SupportedPlatform.IOSVersion` enum only got a `.v18` case in
// PackageDescription 6.0 (Swift 6 toolchain), and there is no `.v18_1`
// case at all. To stay on swift-tools-version 5.9 — matching the rest
// of the workspace — we use the string-based `.iOS(_:)` initializer,
// which accepts arbitrary version strings including "18.1". The
// FoundationModels-using source files (added in Task 40) carry
// `@available(iOS 18.1, *)` attributes for safety. The podspec
// separately pins `s.ios.deployment_target = '18.1'` for app
// integration.
//
// macOS 14 covers the host-side `swift test` compile. The smoke test does
// not import FoundationModels, so the host build does not need iOS 18.1+
// availability.
let package = Package(
    name: "DVAICapacitorFoundation",
    platforms: [.iOS("18.1"), .macOS(.v14)],
    products: [
        .library(name: "DVAICapacitorFoundation", targets: ["DVAICapacitorFoundation"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Building42/Telegraph.git", from: "0.30.0"),
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
