// swift-tools-version: 5.9
//
// examples/ios-coreml — minimal SwiftUI iOS example for the dvai-bridge
// SDK using the CoreML / ANE backend.
//
// IMPORTANT — the .coreml backend is shipped as **experimental**: model
// + tokenizer load and HTTP server boot all succeed, but the first call
// to `MLModel.prediction(from:using:)` against the public reference
// checkpoint hits an unrecovered IRValue-format crash inside CoreML's
// C++ IR layer. See README.md and docs/guide/ios-native-sdk.md#known-issues.
// This example demonstrates the integration shape; the actual chat
// completion may not return on iOS Simulator until the CoreML follow-up
// lands.

import PackageDescription

let package = Package(
    name: "ios-coreml",
    platforms: [.iOS("18.1"), .macOS(.v14)],
    products: [
        .library(name: "IOSCoreMLApp", targets: ["IOSCoreMLApp"]),
    ],
    dependencies: [
        .package(path: "../../packages/dvai-bridge-ios"),
        .package(url: "https://github.com/MacPaw/OpenAI.git", from: "0.4.9"),
    ],
    targets: [
        .target(
            name: "IOSCoreMLApp",
            dependencies: [
                .product(name: "DVAIBridge", package: "dvai-bridge-ios"),
                .product(name: "OpenAI", package: "OpenAI"),
            ],
            path: "Sources/IOSCoreMLApp"
        ),
        .testTarget(
            name: "IOSCoreMLAppTests",
            dependencies: [
                "IOSCoreMLApp",
                .product(name: "DVAIBridge", package: "dvai-bridge-ios"),
            ],
            path: "Tests/IOSCoreMLAppTests"
        ),
    ]
)
