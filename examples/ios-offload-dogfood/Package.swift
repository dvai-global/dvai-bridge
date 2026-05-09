// swift-tools-version: 5.9
//
// examples/ios-offload-dogfood — minimal SwiftUI iOS example that
// FORCES the dvai-bridge SDK into offload-only mode (no local backend).
// Used to dogfood the v3.2 outgoing-offload routing path against a
// real DVAI Hub running on a paired Mac.
//
// What's different from `examples/ios-llama`:
//
//   - No model download. We pass `OffloadConfig(enabled: true,
//     minLocalCapability: 999.0)` so the SDK's pre-init capability
//     assessment returns `.offloadOnly` (no real device hits ~999
//     tok/s). The bridge skips backend init entirely and only
//     brings up the OffloadProxy + OffloadRuntime.
//
//   - Subscribes to `DVAIBridge.shared.pairingRequests()` so when the
//     Hub initiates a pairing handshake, the iOS UI shows an
//     approve/deny dialog.
//
//   - Subscribes to `DVAIBridge.shared.discoveryEvents()` so the
//     dashboard shows discovered peers (the Hub) live.
//
//   - The "Send chat" button hits the OpenAI Swift SDK against
//     `server.baseUrl` and renders each SSE chunk with its
//     wall-clock arrival timestamp — so streaming behavior is
//     visible to the eye. If the proxy were still buffering (the
//     Telegraph 0.40 era), all chunks would land on a single
//     timestamp; with Hummingbird they land staggered.
//
// To open in Xcode: `open Package.swift`. Choose an `iPhone 17` or
// real-device run destination.

import PackageDescription

let package = Package(
    name: "ios-offload-dogfood",
    platforms: [.iOS("18.1"), .macOS(.v14)],
    products: [
        .library(name: "IOSOffloadDogfoodApp", targets: ["IOSOffloadDogfoodApp"]),
    ],
    dependencies: [
        // Path-dep to the in-monorepo iOS SDK.
        .package(path: "../../packages/dvai-bridge-ios"),
        // OpenAI Swift SDK (MacPaw/OpenAI) — points at BoundServer.baseUrl.
        .package(url: "https://github.com/MacPaw/OpenAI.git", from: "0.4.9"),
    ],
    targets: [
        .target(
            name: "IOSOffloadDogfoodApp",
            dependencies: [
                .product(name: "DVAIBridge", package: "dvai-bridge-ios"),
                .product(name: "OpenAI", package: "OpenAI"),
            ],
            path: "Sources/IOSOffloadDogfoodApp"
        ),
    ]
)
