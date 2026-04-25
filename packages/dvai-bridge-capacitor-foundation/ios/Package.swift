// swift-tools-version: 5.9
import PackageDescription

// NOTE on iOS deployment target:
// Apple Foundation Models requires iOS 18.1+ at runtime. SwiftPM's
// `SupportedPlatform.IOSVersion` enum only goes up to `.v18` (which is
// iOS 18.0); there is no `.v18_1` enum case at this swift-tools-version.
// We declare `.iOS(.v18)` here and rely on `@available(iOS 18.1, *)`
// attributes inside the FoundationModels-using source files to enforce
// the real minimum at compile/use sites. The podspec separately pins
// `s.ios.deployment_target = '18.1'` for app integration.
//
// macOS 14 covers the host-side `swift test` compile. The smoke test does
// not import FoundationModels, so the host build does not need iOS 18.1+
// availability.
let package = Package(
    name: "DVAICapacitorFoundation",
    platforms: [.iOS(.v18), .macOS(.v14)],
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
