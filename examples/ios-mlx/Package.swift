// swift-tools-version: 5.9
//
// examples/ios-mlx — minimal SwiftUI iOS example for the dvai-bridge SDK
// using the MLX backend (Apple Silicon-only at runtime).
//
// MLX uses Apple's MLX framework (mlx-swift-lm), which is Apple-Silicon-
// only. The iOS Simulator on Intel Macs has no MLX device; this example
// runs only on Apple Silicon hosts (M1+). SwiftPM-only — see
// docs/guide/ios-native-sdk.md#cocoapods-asymmetries.

import PackageDescription

let package = Package(
    name: "ios-mlx",
    platforms: [.iOS("18.1"), .macOS(.v14)],
    products: [
        .library(name: "IOSMLXApp", targets: ["IOSMLXApp"]),
    ],
    dependencies: [
        .package(path: "../../packages/dvai-bridge-ios"),
        .package(url: "https://github.com/MacPaw/OpenAI.git", from: "0.4.9"),
    ],
    targets: [
        .target(
            name: "IOSMLXApp",
            dependencies: [
                .product(name: "DVAIBridge", package: "dvai-bridge-ios"),
                .product(name: "OpenAI", package: "OpenAI"),
            ],
            path: "Sources/IOSMLXApp"
        ),
        .testTarget(
            name: "IOSMLXAppTests",
            dependencies: [
                "IOSMLXApp",
                .product(name: "DVAIBridge", package: "dvai-bridge-ios"),
            ],
            path: "Tests/IOSMLXAppTests"
        ),
    ]
)
