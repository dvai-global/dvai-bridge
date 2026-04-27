// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DVAICapacitorMLX",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DVAICapacitorMLX", targets: ["DVAICapacitorMLX"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm", branch: "main"),
        // Path dep to the MLX core package's ROOT (not /ios). Identity
        // derived from path's last dir = "dvai-bridge-ios-mlx-core".
        .package(path: "../../dvai-bridge-ios-mlx-core"),
    ],
    targets: [
        .target(
            name: "DVAICapacitorMLX",
            dependencies: [
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm"),
                .product(name: "DVAIMLXCore", package: "dvai-bridge-ios-mlx-core"),
            ],
            path: "Sources/DVAICapacitorMLX"
        ),
        .testTarget(
            name: "DVAICapacitorMLXTests",
            dependencies: [
                "DVAICapacitorMLX",
                .product(name: "DVAIMLXCore", package: "dvai-bridge-ios-mlx-core"),
            ],
            path: "Tests/DVAICapacitorMLXTests"
        ),
    ]
)
