// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DVAICapacitorLlama",
    platforms: [.iOS(.v14), .macOS(.v12)],
    products: [
        .library(name: "DVAICapacitorLlama", targets: ["DVAICapacitorLlama"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Building42/Telegraph.git", from: "0.30.0"),
    ],
    targets: [
        .target(
            name: "DVAICapacitorLlama",
            dependencies: ["Telegraph"],
            path: "Sources/DVAICapacitorLlama",
            exclude: ["PluginProxy.m"],
            cSettings: [
                .headerSearchPath("../../native/llama.cpp/include"),
                .headerSearchPath("../../native/llama.cpp/ggml/include"),
            ],
            cxxSettings: [
                .headerSearchPath("../../native/llama.cpp/include"),
                .headerSearchPath("../../native/llama.cpp/ggml/include"),
                .define("GGML_USE_METAL"),
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Foundation"),
                .linkedFramework("Accelerate"),
            ]
        ),
        .testTarget(
            name: "DVAICapacitorLlamaTests",
            dependencies: ["DVAICapacitorLlama"],
            path: "Tests/DVAICapacitorLlamaTests"
        ),
    ]
)
