// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DVAICapacitorFoundation",
    platforms: [.iOS("18.1"), .macOS(.v14)],
    products: [
        .library(name: "DVAICapacitorFoundation", targets: ["DVAICapacitorFoundation"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm", branch: "main"),
        // Path dep to the core package's ROOT (not /ios). Identity derived
        // from path's last dir = "dvai-bridge-ios-foundation-core".
        .package(path: "../../dvai-bridge-ios-foundation-core"),
    ],
    targets: [
        .target(
            name: "DVAICapacitorFoundation",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm"),
                .product(name: "DVAIFoundationCore", package: "dvai-bridge-ios-foundation-core"),
            ],
            path: "Sources/DVAICapacitorFoundation",
            exclude: ["PluginProxy.m"]
        ),
        .testTarget(
            name: "DVAICapacitorFoundationTests",
            dependencies: [
                "DVAICapacitorFoundation",
                .product(name: "DVAIFoundationCore", package: "dvai-bridge-ios-foundation-core"),
            ],
            path: "Tests/DVAICapacitorFoundationTests"
        ),
    ]
)
