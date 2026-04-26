// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DVAILlamaCore",
    platforms: [.iOS(.v14), .macOS(.v12)],
    products: [
        .library(name: "DVAILlamaCore", targets: ["DVAILlamaCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Building42/Telegraph.git", from: "0.40.0"),
    ],
    targets: [
        // Prebuilt llama.xcframework — produced by upstream's
        // build-xcframework.sh, materialized by `bash scripts/mac-side-prepare-xcframework.sh`.
        // The xcframework is gitignored; CI must run the prepare step before
        // iOS jobs. Path is cross-package during Phase 3A's iOS-first window
        // (Tasks 2-8); Task 9 relocates the submodule + xcframeworks into
        // dvai-bridge-android-llama-core and updates this path.
        .binaryTarget(
            name: "llama",
            path: "../../dvai-bridge-capacitor-llama/native/llama.cpp/build-apple/llama.xcframework"
        ),
        .binaryTarget(
            name: "mtmd",
            path: "../../dvai-bridge-capacitor-llama/native/llama.cpp/build-apple/mtmd.xcframework"
        ),
        // ObjC++ target — LlamaCppBridge.{h,mm}, links against the binary targets above.
        .target(
            name: "DVAILlamaCoreObjC",
            dependencies: ["llama", "mtmd"],
            path: "ios/Sources/DVAILlamaCoreObjC",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Foundation"),
            ]
        ),
        // Swift target — depends on the ObjC++ target and Telegraph.
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
    ],
    cxxLanguageStandard: .cxx17
)
