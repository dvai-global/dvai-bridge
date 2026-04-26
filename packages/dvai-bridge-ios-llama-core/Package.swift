// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DVAILlamaCore",
    platforms: [.iOS(.v14), .macOS(.v12)],
    products: [
        .library(name: "DVAILlamaCore", targets: ["DVAILlamaCore"]),
        .library(name: "DVAILlamaCoreObjC", targets: ["DVAILlamaCoreObjC"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Building42/Telegraph.git", from: "0.40.0"),
    ],
    targets: [
        // Prebuilt llama.xcframework — produced by upstream's
        // build-xcframework.sh, materialized by `bash scripts/mac-side-prepare-xcframework.sh`.
        // The xcframework is gitignored; CI must run the prepare step before
        // iOS jobs. The submodule + xcframeworks live in
        // dvai-bridge-android-llama-core (Phase 3A Task 9 relocation).
        .binaryTarget(
            name: "llama",
            path: "../dvai-bridge-android-llama-core/android/src/main/cpp/native/llama.cpp/build-apple/llama.xcframework"
        ),
        .binaryTarget(
            name: "mtmd",
            path: "../dvai-bridge-android-llama-core/android/src/main/cpp/native/llama.cpp/build-apple/mtmd.xcframework"
        ),
        // Package.swift lives at the package root (not under `ios/`), so target
        // paths include the `ios/` prefix. The root placement avoids an SPM
        // identity-collision with sibling packages whose manifests also live at
        // `<pkg>/ios/Package.swift` — SPM derives a path-dep's identity from
        // the last directory component of the path, and "ios" would alias
        // multiple packages and trigger a false cyclic-dependency error.
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
