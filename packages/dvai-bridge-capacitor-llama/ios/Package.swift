// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DVAICapacitorLlama",
    platforms: [.iOS(.v14), .macOS(.v12)],
    products: [
        .library(name: "DVAICapacitorLlama", targets: ["DVAICapacitorLlama"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Building42/Telegraph.git", from: "0.40.0"),
    ],
    targets: [
        // Prebuilt llama.xcframework produced by upstream's
        // native/llama.cpp/build-xcframework.sh. Upstream removed
        // Package.swift after tag b4823 (March 2025), so we can no longer do
        // a path-based SPM dependency on the submodule. Run
        // `bash scripts/mac-side-prepare-xcframework.sh` on a Mac after every
        // submodule SHA bump to (re)build this artifact. The xcframework is
        // gitignored; CI must run the prepare step before iOS jobs.
        //
        // The xcframework's modulemap re-exports llama.h, ggml.h, ggml-alloc.h,
        // ggml-backend.h, ggml-metal.h, ggml-cpu.h, ggml-blas.h and gguf.h so
        // existing `#import "llama.h"` etc. in LlamaCppBridge.mm continue to
        // resolve. Metal / Accelerate / Foundation are linked from inside the
        // framework's modulemap.
        .binaryTarget(
            name: "llama",
            path: "../native/llama.cpp/build-apple/llama.xcframework"
        ),
        // ObjC++ target — contains LlamaCppBridge.{h,mm} and links against the
        // llama.xcframework binary target above.
        .target(
            name: "DVAICapacitorLlamaObjC",
            dependencies: ["llama"],
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
