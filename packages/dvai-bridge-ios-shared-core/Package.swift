// swift-tools-version: 5.9
import PackageDescription

// Shared HTTP-server + handler-dispatch types used by ALL backend cores
// (llama / foundation / coreml / mlx). This package was extracted from
// DVAILlamaCore so non-llama backends don't transitively pull in
// llama.xcframework + mtmd.xcframework — that coupling was the only
// thing preventing per-backend Mac Catalyst support, since llama.cpp's
// `build-xcframework.sh` doesn't produce a Catalyst slice.
//
// Public types here:
//   - HandlerContext, HandlerResponse, DVAIHandlers (HandlerContext.swift)
//   - CORSConfig, dispatchRoute, formatResponse (HandlerDispatch.swift)
//   - HttpServer (HttpServer.swift)
//
// Platform floor matches the most permissive consumer (DVAILlamaCore =
// iOS 14 / macOS 12). Other consumers (DVAIFoundationCore, DVAIMLXCore,
// DVAIBridge) raise their own minimums independently.
let package = Package(
    name: "DVAISharedCore",
    platforms: [.iOS(.v14), .macOS(.v12)],
    products: [
        .library(name: "DVAISharedCore", targets: ["DVAISharedCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Building42/Telegraph.git", from: "0.40.0"),
    ],
    targets: [
        .target(
            name: "DVAISharedCore",
            dependencies: ["Telegraph"],
            path: "ios/Sources/DVAISharedCore"
        ),
        .testTarget(
            name: "DVAISharedCoreTests",
            dependencies: ["DVAISharedCore"],
            path: "ios/Tests/DVAISharedCoreTests"
        ),
    ]
)
