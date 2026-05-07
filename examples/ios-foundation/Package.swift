// swift-tools-version: 5.9
//
// examples/ios-foundation — minimal SwiftUI iOS example for the
// dvai-bridge SDK using Apple Foundation Models (iOS 26+ runtime).
//
// No model download — the on-device LLM is managed by Apple Intelligence.
// SwiftPM-only by design (the .foundation backend's transitive autolink
// directives are incompatible with CocoaPods — see
// docs/guide/ios-native-sdk.md#cocoapods-asymmetries).

import PackageDescription

let package = Package(
    name: "ios-foundation",
    platforms: [.iOS("18.1"), .macOS(.v14)],
    products: [
        .library(name: "IOSFoundationApp", targets: ["IOSFoundationApp"]),
    ],
    dependencies: [
        .package(path: "../../packages/dvai-bridge-ios"),
        .package(url: "https://github.com/MacPaw/OpenAI.git", from: "0.4.9"),
    ],
    targets: [
        .target(
            name: "IOSFoundationApp",
            dependencies: [
                .product(name: "DVAIBridge", package: "dvai-bridge-ios"),
                .product(name: "OpenAI", package: "OpenAI"),
            ],
            path: "Sources/IOSFoundationApp"
        ),
        .testTarget(
            name: "IOSFoundationAppTests",
            dependencies: [
                "IOSFoundationApp",
                .product(name: "DVAIBridge", package: "dvai-bridge-ios"),
            ],
            path: "Tests/IOSFoundationAppTests"
        ),
    ]
)
