// swift-tools-version: 5.9
import PackageDescription

// NOTE: capacitor-mediapipe is Android-only at runtime. The iOS plugin in
// `Sources/DVAICapacitorMediaPipe` is a stub that rejects every method
// with "MediaPipe LLM is Android-only." It exists so app builds that
// happen to include the package on the iOS side still link cleanly.
// Telegraph stays as a dependency for parity with the other capacitor-*
// packages (the stub itself doesn't reach for it, but Internal/* files
// that may land later — e.g. a reusable HttpServer wrapper — would).
let package = Package(
    name: "DVAICapacitorMediaPipe",
    // iOS 17 / macOS 14 — bumped from .v14/.v12 to match the shared-core
    // floor that v3.2.0 raised when migrating off Telegraph onto
    // Hummingbird. capacitor-foundation already declares .iOS("18.1");
    // capacitor-mlx already .iOS(.v17); capacitor-llama bumped in the
    // same commit. mediapipe was the lone laggard.
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DVAICapacitorMediaPipe", targets: ["DVAICapacitorMediaPipe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Building42/Telegraph.git", from: "0.40.0"),
    ],
    targets: [
        .target(
            name: "DVAICapacitorMediaPipe",
            dependencies: ["Telegraph"],
            path: "Sources/DVAICapacitorMediaPipe",
            exclude: ["PluginProxy.m"]
        ),
        .testTarget(
            name: "DVAICapacitorMediaPipeTests",
            dependencies: ["DVAICapacitorMediaPipe"],
            path: "Tests/DVAICapacitorMediaPipeTests"
        ),
    ]
)
