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
//   - DVAIRequest, DVAIResponse, DVAIHttpMethod (HandlerContext.swift)
//   - CORSConfig, dispatchRoute, formatResponse (HandlerDispatch.swift)
//   - HttpServer (HttpServer.swift)
//
// v3.2.0 — migrated off Telegraph onto Hummingbird. Telegraph 0.40
// buffered SSE bodies server-side AND its private HTTPParserC clang
// module collided with swift-nio's CNIOLLHTTP whenever a downstream
// target imported both. Hummingbird (built on swift-nio) gives us
// proper streaming SSE plus a single, consistent C-module footprint
// across DVAISharedCore, DVAIBridge, and the OffloadProxy. Public
// API surface is unchanged: HttpServer.installRoutes / tryBind / stop
// signatures match the Telegraph era 1:1 (the only call-site change
// is install-then-bind ordering, since Hummingbird requires the
// router at Application construction time).
//
// Platform floor: iOS 17 / macOS 14 — Hummingbird 2.x's own minimum.
// Earlier (Telegraph era) we shipped iOS 14 / macOS 12; the SSE
// streaming + cross-platform clang-module fix in v3.2.0 required
// migrating to swift-nio's HTTP stack, which carries the iOS 17 floor
// transitively. Backend cores bump their floors to match (DVAILlamaCore
// → 17/14; DVAIFoundationCore + DVAIMLXCore + DVAIBridge already at
// iOS 17+/macOS 14+).
let package = Package(
    name: "DVAISharedCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DVAISharedCore", targets: ["DVAISharedCore"]),
    ],
    dependencies: [
        // Hummingbird 2.x — our HTTP server backbone. Built on swift-nio
        // so we get streaming SSE response bodies for free. Pinned to
        // 2.0.0 minor so swift-nio dep ranges line up with mlx-swift's
        // pins; can be relaxed once Hummingbird 3 stabilises.
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "DVAISharedCore",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
            ],
            path: "ios/Sources/DVAISharedCore"
        ),
        .testTarget(
            name: "DVAISharedCoreTests",
            dependencies: ["DVAISharedCore"],
            path: "ios/Tests/DVAISharedCoreTests"
        ),
    ]
)
