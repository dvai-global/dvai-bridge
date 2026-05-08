// swift-tools-version: 5.9
import PackageDescription

// FoundationModels deployment-target rationale: link-time floor is iOS 18.1
// (the SDK-emitted symbols are weak-linked and resolve at runtime); the
// FoundationModels public API itself is `@available(iOS 26.0, *)` in the
// Xcode 26.4 SDK, so calling it requires runtime guarding. SwiftPM 5.9's
// `.iOS` enum maxes out at `.v17`, hence the string-based `.iOS(_:)`
// initializer which accepts arbitrary version strings like "18.1".
let package = Package(
    name: "DVAIFoundationCore",
    platforms: [.iOS("18.1"), .macOS(.v14)],
    products: [
        .library(name: "DVAIFoundationCore", targets: ["DVAIFoundationCore"]),
    ],
    dependencies: [
        // Shared HTTP-server / handler-dispatch types (formerly duplicated
        // inline; now extracted into dvai-bridge-ios-shared-core for reuse
        // across all backend cores). Path-dep identity =
        // "dvai-bridge-ios-shared-core". DVAISharedCore brings in
        // Hummingbird transitively as of v3.2.0 — the iOS HTTP server
        // backbone is no longer Telegraph.
        .package(path: "../dvai-bridge-ios-shared-core"),
    ],
    targets: [
        // Package.swift sits at the package ROOT (not under `ios/`) so SPM derives
        // identity "dvai-bridge-ios-foundation-core" — unique among siblings.
        // Target paths are relative to Package.swift, hence the `ios/` prefix.
        .target(
            name: "DVAIFoundationCore",
            dependencies: [
                .product(name: "DVAISharedCore", package: "dvai-bridge-ios-shared-core"),
            ],
            path: "ios/Sources/DVAIFoundationCore"
        ),
        .testTarget(
            name: "DVAIFoundationCoreTests",
            dependencies: [
                "DVAIFoundationCore",
                .product(name: "DVAISharedCore", package: "dvai-bridge-ios-shared-core"),
            ],
            path: "ios/Tests/DVAIFoundationCoreTests"
        ),
    ]
)
