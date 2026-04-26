// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DVAILlamaCore",
    platforms: [.iOS(.v14)],
    products: [
        .library(name: "DVAILlamaCore", targets: ["DVAILlamaCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Building42/Telegraph.git", from: "0.40.0"),
    ],
    targets: [
        .target(
            name: "DVAILlamaCoreObjC",
            path: "ios/Sources/DVAILlamaCoreObjC",
            publicHeadersPath: "include"
        ),
        .target(
            name: "DVAILlamaCore",
            dependencies: ["DVAILlamaCoreObjC", "Telegraph"],
            path: "ios/Sources/DVAILlamaCore"
        ),
        .testTarget(
            name: "DVAILlamaCoreTests",
            dependencies: ["DVAILlamaCore", "DVAILlamaCoreObjC"],
            path: "ios/Tests/DVAILlamaCoreTests"
        ),
    ]
)
