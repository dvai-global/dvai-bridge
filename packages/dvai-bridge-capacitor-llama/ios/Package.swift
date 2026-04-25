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
        // Path-based dependency on the vendored llama.cpp submodule. Its
        // bundled Package.swift exposes a `llama` library product that
        // compiles src/*.cpp + ggml/* and links Metal/Accelerate on Darwin.
        .package(name: "llama", path: "../native/llama.cpp"),
    ],
    targets: [
        // ObjC++ target — contains LlamaCppBridge.{h,mm} and links against the
        // llama.cpp static library exposed via the path-dep above. Public
        // headers (llama.h, ggml.h, …) come from llama.cpp's own
        // `publicHeadersPath: "spm-headers"` so we don't need manual
        // headerSearchPath entries any more.
        .target(
            name: "DVAICapacitorLlamaObjC",
            dependencies: [
                .product(name: "llama", package: "llama"),
            ],
            path: "Sources/DVAICapacitorLlamaObjC",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation"),
            ]
        ),
        // Swift target — depends on the ObjC++ target
        .target(
            name: "DVAICapacitorLlama",
            dependencies: ["DVAICapacitorLlamaObjC", "Telegraph"],
            path: "Sources/DVAICapacitorLlama",
            exclude: ["PluginProxy.m"]
        ),
        .testTarget(
            name: "DVAICapacitorLlamaTests",
            dependencies: ["DVAICapacitorLlama", "DVAICapacitorLlamaObjC"],
            path: "Tests/DVAICapacitorLlamaTests"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
