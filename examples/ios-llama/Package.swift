// swift-tools-version: 5.9
//
// examples/ios-llama — minimal SwiftUI iOS example for the dvai-bridge SDK
// using the llama.cpp backend (GGUF model, Metal acceleration).
//
// This is a path-dep example: it consumes the in-monorepo
// `packages/dvai-bridge-ios` SwiftPM package via a relative `:path` ref.
// To open in Xcode: `open Package.swift`. Xcode will resolve the path
// dependencies and let you run the `IOSLlamaApp` executable on a
// simulator (iPhone 16, iOS 18.5+).
//
// See README.md for prereqs (Mac + Xcode 16+) and the model-download flow.

import PackageDescription

let package = Package(
    name: "ios-llama",
    platforms: [.iOS("18.1"), .macOS(.v14)],
    products: [
        .library(name: "IOSLlamaApp", targets: ["IOSLlamaApp"]),
    ],
    dependencies: [
        // Path-dep to the in-monorepo iOS SDK. The package's identity is
        // derived from the directory name `dvai-bridge-ios`.
        .package(path: "../../packages/dvai-bridge-ios"),
        // OpenAI Swift SDK (MacPaw/OpenAI) — the canonical idiomatic
        // OpenAI client for Swift. Pointed at `BoundServer.baseUrl`.
        .package(url: "https://github.com/MacPaw/OpenAI.git", from: "0.4.9"),
    ],
    targets: [
        .target(
            name: "IOSLlamaApp",
            dependencies: [
                .product(name: "DVAIBridge", package: "dvai-bridge-ios"),
                .product(name: "OpenAI", package: "OpenAI"),
            ],
            path: "Sources/IOSLlamaApp"
        ),
        .testTarget(
            name: "IOSLlamaAppTests",
            dependencies: [
                "IOSLlamaApp",
                .product(name: "DVAIBridge", package: "dvai-bridge-ios"),
            ],
            path: "Tests/IOSLlamaAppTests"
        ),
    ]
)
