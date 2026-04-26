# Phase 3C — iOS Native SDK (`@dvai-bridge/ios` / `DVAIBridge`)

**Status:** Draft — awaiting review
**Date:** 2026-04-26
**Scope:** New top-level iOS SDK package that wraps the Phase 3A core packages (`DVAILlamaCore` + `DVAIFoundationCore`) plus a new CoreML backend, exposes the same OpenAI-compatible HTTP surface as the rest of the dvai-bridge family, and ships via SPM + CocoaPods.

**Sub-phase position in Phase 3:**

```
3A core extraction ✅ → 3B LiteRT-LM migration ✅ → 3C iOS SDK ◀️ YOU ARE HERE
                                                  → 3D Android AAR
                                                  → 3E React Native
                                                  → 3F Flutter
                                                  → 3G .NET NuGet
                                                  → 3H docs / publish / launch
```

3C is mostly extraction + thin wrapping (DVAILlamaCore + DVAIFoundationCore are already standing) plus one new backend (CoreML). 3D will follow the same pattern on the Android side.

---

## 1. Goals

1. Stand up `packages/dvai-bridge-ios/` with a single SPM package at the package root and a CocoaPods podspec, ready for SPM-by-URL (`https://github.com/Westenets/dvai-bridge-ios.git`) and `pod 'DVAIBridge'` installs once the repo is split / a sub-tree is published.
2. Public API: `DVAIBridge.shared` singleton that exposes the same 8-method surface the Capacitor JS shim has, plus iOS-native conveniences (Combine publishers, `@Observable` reactive properties, AsyncStream progress).
3. Backend selection at `start()`-time: `auto` (default), `llama`, `foundation`, `coreml`. `auto` resolves at runtime to the best-available backend for the device.
4. Three concrete backends:
   - **llama.cpp** via `DVAILlamaCore` — already shipping on Capacitor; lift-and-reuse.
   - **Apple Foundation Models** via `DVAIFoundationCore` — already shipping on Capacitor; lift-and-reuse.
   - **CoreML** — new in 3C. **Initial scope**: package scaffolding + a stub PluginState that throws `notYetImplemented` from `start()`. Full text-generation lands in a follow-up sub-phase (3C+) with a dedicated spec.
5. Ship a pure-Swift integration test that proves a non-Capacitor consumer can `import DVAIBridge`, call `start()`, hit `http://127.0.0.1:38883/v1/chat/completions`, and get a response — same behavior as the Capacitor path.
6. Reuse the existing xcframework binary distribution (llama.framework + mtmd.framework already produced by `scripts/mac-side-prepare-xcframework.sh`); 3C just hooks new SPM/podspec entries onto them.

## 2. Non-goals (3C)

- A complete CoreML LLM backend with tokenization, KV-cache, sampling, etc. That's a follow-up sub-phase (call it 3C.2 when the time comes).
- Publishing to Swift Package Index or CocoaPods Trunk — Phase 3H ships the publish flow.
- Any work on `dvai-bridge-ios-llama-core` or `dvai-bridge-ios-foundation-core` source. They stay frozen except for any **new public symbols** the SDK needs them to expose (those are surgical additions, not refactors).
- Anything Android, .NET, RN, Flutter, or web. 3C is iOS-only.
- React Native / Flutter wrappers consuming this SDK. Those are 3E and 3F.
- Apple Watch / tvOS / visionOS support. iOS + iPadOS + macOS Catalyst only (the platforms currently supported by the underlying cores' `Package.swift` declarations).
- Renaming or restructuring the existing core packages. They stay at their current paths.

## 3. Architecture

### 3.1 Package layout

```
packages/dvai-bridge-ios/
├── package.json                                    # @dvai-bridge/ios npm metadata
├── README.md                                       # synced via scripts/sync-package-meta.js
├── Package.swift                                   # SPM manifest at package root (identity = "dvai-bridge-ios")
├── DVAIBridge.podspec                              # CocoaPods spec
└── ios/
    ├── Sources/
    │   ├── DVAIBridge/                             # public Swift API
    │   │   ├── DVAIBridge.swift                    # the singleton + start()/stop()/etc.
    │   │   ├── DVAIBridgeError.swift               # public error type
    │   │   ├── DVAIBridgeConfig.swift              # StartOptions analog
    │   │   ├── BoundServer.swift                   # StartResult analog
    │   │   ├── ProgressEvent.swift                 # Progress + Combine publisher
    │   │   ├── BackendKind.swift                   # enum: .auto, .llama, .foundation, .coreml
    │   │   ├── BackendSelector.swift               # picks the right backend at runtime
    │   │   ├── ReactiveState.swift                 # @Observable wrapper for baseUrl/port/isReady
    │   │   └── (no actual backend logic — that's in the cores or DVAICoreMLCore)
    │   └── DVAICoreMLCore/                         # new backend module (stub for 3C)
    │       ├── CoreMLPluginState.swift             # mirrors the core PluginState shape; throws notYetImplemented
    │       ├── CoreMLHandlers.swift                # placeholder DVAIHandlers conformer
    │       └── CoreMLBackendError.swift            # .notYetImplemented (and future error cases)
    └── Tests/
        └── DVAIBridgeTests/
            ├── DVAIBridgeAPIShapeTests.swift       # asserts the 8-method surface compiles + has correct signatures
            ├── BackendSelectorTests.swift          # auto-selection logic
            ├── ProgressEventTests.swift            # Combine + AsyncStream emission
            ├── CoreMLStubTests.swift               # asserts the stub throws as expected
            └── IntegrationTests.swift              # end-to-end: start() → curl /v1/models → stop()
```

`Package.swift` at the **package root** (not under `ios/`) — same SPM-identity-collision lesson learned in Phase 3A. Identity becomes `dvai-bridge-ios`, distinct from sibling packages.

### 3.2 Public API surface

```swift
import DVAIBridge

// Singleton entry-point
let server = try await DVAIBridge.shared.start(.init(
    backend: .auto,                    // .auto | .llama | .foundation | .coreml
    modelPath: "/path/to/model.gguf",  // optional; required for llama
    mmprojPath: "/path/to/mmproj.gguf",
    contextSize: 2048,
    threads: 4,
    httpBasePort: 38883,
    httpMaxPortAttempts: 16,
    corsOrigin: .wildcard
))

print(server.baseUrl)  // http://127.0.0.1:38883/v1
print(server.port)     // 38883
print(server.backend)  // BackendKind
print(server.modelId)

// Status
let info = await DVAIBridge.shared.status()
print(info.running, info.backend, info.baseUrl)

// Stop
try await DVAIBridge.shared.stop()

// Progress events — three idiomatic surfaces, pick the one that fits your app
let cancellable = DVAIBridge.shared.progressPublisher
    .sink { event in print("progress: \(event.phase)") }

for await event in DVAIBridge.shared.progressStream {
    print(event)
}

await DVAIBridge.shared.addProgressListener { event in
    print(event)
}

// Model management (delegates to DVAILlamaCore.ModelDownloader)
let result = try await DVAIBridge.shared.downloadModel(.init(
    url: URL(string: "https://...")!,
    sha256: "deadbeef...",
    destFilename: "gemma-2b.gguf"
))
let cached = try await DVAIBridge.shared.listCachedModels()
try await DVAIBridge.shared.deleteCachedModel(filename: "gemma-2b.gguf")
let dir = try await DVAIBridge.shared.cacheDir()

// Reactive (SwiftUI-ready)
struct MyView: View {
    @Observable @ObservableObject var bridge = DVAIBridge.shared.reactive

    var body: some View {
        if bridge.isReady {
            Text("AI live at \(bridge.baseUrl ?? "")")
        }
    }
}
```

### 3.3 Backend selection (`auto` resolution)

```swift
public enum BackendKind: Sendable {
    case auto
    case llama
    case foundation
    case coreml
}

// Auto selection logic (BackendSelector.swift):
//
//   1. If config.modelPath is a path to a .gguf file (or no file specified
//      and a default GGUF is on disk) → .llama
//   2. If iOS 26+ runtime AND no modelPath provided → .foundation
//   3. If config.modelPath is a path ending in .mlmodelc / .mlpackage → .coreml
//   4. Otherwise → throw ConfigurationError("auto backend requires a hint")
//
// .auto is conservative — it does not auto-discover models. The host app's
// expectation is "pick the right backend for the file I'm pointing at, OR
// pick foundation if I want Apple-managed". If the heuristic can't decide,
// throw rather than guess.
```

### 3.4 Reactive getters (`@Observable` / `ObservableObject`)

```swift
// ReactiveState.swift — main-actor-isolated for SwiftUI
@MainActor
public final class DVAIBridgeReactiveState: ObservableObject {
    @Published public private(set) var isReady: Bool = false
    @Published public private(set) var baseUrl: String? = nil
    @Published public private(set) var port: Int? = nil
    @Published public private(set) var currentBackend: BackendKind? = nil
    @Published public private(set) var lastProgress: ProgressEvent? = nil
}

// Bridge updates this on lifecycle transitions:
//   start() succeeds → isReady = true, baseUrl + port + currentBackend set
//   stop() → all reset
//   progress events → lastProgress
```

For Swift 5.9+ + iOS 17+ contexts, also expose a parallel `@Observable` macro-based form (no `ObservableObject` needed). For iOS < 17, fall back to the `ObservableObject` form.

### 3.5 Progress events — three idiomatic surfaces

A single internal `progressBroadcaster` (continuation-backed). Three public adapters:

1. **AsyncStream** — `DVAIBridge.shared.progressStream: AsyncStream<ProgressEvent>` — for `for await` loops. Cancellable per consumer.
2. **Combine publisher** — `DVAIBridge.shared.progressPublisher: AnyPublisher<ProgressEvent, Never>` — for SwiftUI / Combine pipelines.
3. **Callback** — `addProgressListener(_:) → CancellationToken` — for AppKit-style delegates and bridges.

All three observe the same broadcaster; they don't cause double-fire.

`ProgressEvent` mirrors the existing TS / Capacitor `ProgressEvent`:

```swift
public struct ProgressEvent: Sendable, Equatable {
    public enum Phase: String, Sendable, Codable {
        case download, verify, load, ready, error
    }
    public let phase: Phase
    public let bytesReceived: Int64?
    public let bytesTotal: Int64?
    public let percent: Double?
    public let message: String?
}
```

### 3.6 Error type

```swift
public enum DVAIBridgeError: Error, LocalizedError, Sendable {
    case notStarted
    case alreadyStarted(currentBackend: BackendKind, baseUrl: String)
    case configurationInvalid(reason: String)
    case backendUnavailable(BackendKind, reason: String)   // e.g. .foundation on iOS < 26
    case modelLoadFailed(reason: String)
    case downloadFailed(reason: String)
    case checksumMismatch
    case backendError(underlying: Error)
}
```

Maps cleanly from the underlying core's thrown errors via a small adapter.

## 4. CoreML backend — minimal stub for 3C

Phase 3C ships the package shape so a future sub-phase can fill in the LLM logic without restructuring. The stub:

```swift
public actor CoreMLPluginState {
    public init() {}
    
    public func start(opts: [String: Any]) async throws -> [String: Any] {
        throw CoreMLBackendError.notYetImplemented(
            "CoreML LLM generation is not yet implemented. Use .llama or .foundation instead."
        )
    }
    
    public func stop() async throws {}
    public func statusInfo() -> [String: Any] { ["running": false] }
}

public enum CoreMLBackendError: Error, LocalizedError, Sendable {
    case notYetImplemented(String)
    
    public var errorDescription: String? {
        switch self {
        case .notYetImplemented(let msg): return msg
        }
    }
}
```

Why ship the stub instead of just deferring entirely:
- The package's `Package.swift` declares the target now; future work just edits `CoreMLPluginState.swift` rather than restructuring.
- The `BackendKind.coreml` enum case exists, so callers writing forward-looking code compile today.
- A `CoreMLStubTests.swift` test asserts `start()` throws the expected error — regression catches future accidental "false success" implementations that don't actually work.

3C+ (the follow-up sub-phase) replaces the stub with real implementation; spec for that gets written when scope is clear (likely depends on which CoreML LLM checkpoints are usable — `apple/coreml-llama-3.1`, `coreml-stable-diffusion`, etc.).

## 5. Distribution

### 5.1 SPM

`Package.swift` at `packages/dvai-bridge-ios/Package.swift`:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DVAIBridge",
    platforms: [.iOS(.v14), .macOS(.v12)],
    products: [
        .library(name: "DVAIBridge", targets: ["DVAIBridge"]),
        .library(name: "DVAICoreMLCore", targets: ["DVAICoreMLCore"]),
    ],
    dependencies: [
        .package(path: "../dvai-bridge-ios-llama-core"),
        .package(path: "../dvai-bridge-ios-foundation-core"),
    ],
    targets: [
        .target(
            name: "DVAICoreMLCore",
            path: "ios/Sources/DVAICoreMLCore"
        ),
        .target(
            name: "DVAIBridge",
            dependencies: [
                .product(name: "DVAILlamaCore", package: "dvai-bridge-ios-llama-core"),
                .product(name: "DVAIFoundationCore", package: "dvai-bridge-ios-foundation-core"),
                "DVAICoreMLCore",
            ],
            path: "ios/Sources/DVAIBridge"
        ),
        .testTarget(
            name: "DVAIBridgeTests",
            dependencies: [
                "DVAIBridge",
                .product(name: "DVAILlamaCore", package: "dvai-bridge-ios-llama-core"),
                .product(name: "DVAIFoundationCore", package: "dvai-bridge-ios-foundation-core"),
                "DVAICoreMLCore",
            ],
            path: "ios/Tests/DVAIBridgeTests"
        ),
    ]
)
```

Package identity: `dvai-bridge-ios` (from the directory name). Path-relative deps to the two existing core packages — they sit as siblings under `packages/`.

### 5.2 CocoaPods

`DVAIBridge.podspec` at `packages/dvai-bridge-ios/DVAIBridge.podspec`:

```ruby
require 'json'
package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

Pod::Spec.new do |s|
  s.name             = 'DVAIBridge'
  s.version          = package['version']
  s.summary          = 'iOS SDK for dvai-bridge — embedded local OpenAI server.'
  s.license          = 'Custom (See LICENSE)'
  s.homepage         = package['repository']['url']
  s.author           = package['author']
  s.source           = { :git => package['repository']['url'], :tag => "v#{s.version}" }
  s.platform         = :ios, '14.0'
  s.swift_version    = '5.9'
  s.source_files     = [
    'ios/Sources/DVAIBridge/**/*.{swift}',
    'ios/Sources/DVAICoreMLCore/**/*.{swift}',
    '../dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCore/**/*.{swift}',
    '../dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCoreObjC/**/*.{h,mm}',
    '../dvai-bridge-ios-foundation-core/ios/Sources/DVAIFoundationCore/**/*.{swift}',
  ]
  s.public_header_files = '../dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCoreObjC/include/*.h'
  s.dependency 'Telegraph', '~> 0.40'
  s.vendored_frameworks = [
    '../dvai-bridge-android-llama-core/android/src/main/cpp/native/llama.cpp/build-apple/llama.xcframework',
    '../dvai-bridge-android-llama-core/android/src/main/cpp/native/llama.cpp/build-apple/mtmd.xcframework',
  ]
end
```

The CocoaPods consumer ends up with one pod containing all three Swift modules' sources — same bundling pattern Phase 3A used for the Capacitor wrappers' podspecs. The two xcframeworks ship as `vendored_frameworks` referenced from their actual location in the Android core (the submodule's home post-Phase 3A).

### 5.3 SPM consumer install (target end-state)

```swift
// In a host app's Package.swift
dependencies: [
    .package(url: "https://github.com/Westenets/dvai-bridge.git", from: "1.7.0"),
],
targets: [
    .target(name: "App", dependencies: [
        .product(name: "DVAIBridge", package: "dvai-bridge"),
    ])
]
```

Phase 3H wires the `from: "1.7.0"` resolution to point at the `packages/dvai-bridge-ios/` subdir via SPM's monorepo support. For Phase 3C we ship the package; the install URL works as soon as a tag exists.

## 6. Testing strategy

### 6.1 Unit tests (no real model load)

- `DVAIBridgeAPIShapeTests.swift` — purely shape; asserts `DVAIBridge.shared.start(.init(...))` compiles, return type is `BoundServer`, `ProgressEvent` Codable round-trip, etc. Catches API regressions on every PR.
- `BackendSelectorTests.swift` — exercises every branch of the `auto` heuristic with a fake `FileSystem` injected. Verifies the throwing case ("auto backend requires a hint").
- `ProgressEventTests.swift` — Combine subscriber receives events, AsyncStream `for await` consumes events, callback `addProgressListener` is invoked with a `CancellationToken` that suppresses further events. All three observers see the same broadcast.
- `CoreMLStubTests.swift` — `try await CoreMLPluginState().start([:])` throws `CoreMLBackendError.notYetImplemented`. Regression test against a future "soft" implementation.
- `ReactiveStateTests.swift` — `start()` flips `isReady`, populates `baseUrl`, `currentBackend`. `stop()` resets. Verified on the `@Observable` and `ObservableObject` paths (or just one if pre-iOS 17 fallback isn't compiled).

### 6.2 Integration tests (real HTTP server)

- `IntegrationTests.swift` — boots `DVAIBridge.shared` with `.foundation` (no model file required) on iOS 26+ runners, hits `http://127.0.0.1:<port>/v1/models`, asserts non-empty JSON response. On pre-iOS-26 runners, falls back to `.llama` with a `.gguf` fixture if available; otherwise XCTSkip's. The point is to prove the packaging works for non-Capacitor consumers.

### 6.3 CI

`.github/workflows/test-ios-bridge.yml` — runs `xcodebuild test -scheme DVAIBridge -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5'`. Triggers on changes to `packages/dvai-bridge-ios/**` or to either core. Uploads xcresult on failure.

## 7. Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| `Package.swift` path-dep collisions with the existing cores again | Med | Med | Different identity (`dvai-bridge-ios`); same fix as Phase 3A — manifest at package root |
| `xcframework` vendored-framework path crosses package boundaries (CocoaPods) | Low | Med | Already works in Phase 3A's podspecs; copy the pattern verbatim |
| Auto-backend heuristic too aggressive / not aggressive enough; user hits a confusing error | Med | Low-Med | Throw on ambiguity; always hint the explicit `.llama` / `.foundation` / `.coreml` path in the error message |
| iOS 26 runtime checks complicate testing on pre-26 simulators | Med | Med | Wrap every `LanguageModelSession` call in `if #available(iOS 26, *)`; XCTSkip on older runners; CI matrix runs both to guarantee |
| CoreML backend stub gets accidentally exercised in CI smoke if heuristic mis-routes | Low | Low | `CoreMLStubTests.swift` ensures any false positive throws; smoke skips `.coreml` explicitly |
| The new SDK package ships symbols that conflict with capacitor-* packages | Low | Med | Module namespaces are distinct (`DVAIBridge` vs `DVAICapacitorLlama`); no symbol collision possible |
| Reactive state outlives the SDK on lifecycle changes (memory retention) | Low | Low | `weak self` everywhere; explicit teardown on `stop()` |

## 8. Open questions / deferred decisions

1. **`@Observable` (Swift 5.9 macro) vs `ObservableObject` (Combine)** — both? One? The macro path requires iOS 17+; `ObservableObject` works back to 13. Decision: ship both and let consumers pick. Spec mentions; plan implements both.
2. **Distributing xcframeworks** — vendored from the Android core's submodule directory works for SPM (`binaryTarget(path:)`) and for CocoaPods (`vendored_frameworks`) at dev time, but for published consumption we need to host the xcframework artifacts on GitHub Releases (or similar) and reference them by URL + checksum. Phase 3H handles publishing; for Phase 3C we just verify dev-time SPM + CocoaPods builds work locally.
3. **macOS Catalyst** — the cores declare `.macOS(.v12)` so Catalyst is implicitly possible. Worth a smoke test on macOS too. Spec includes the platform; plan covers a basic Catalyst test.
4. **DVAIBridge.shared singleton vs explicit instances** — singleton is the canonical entry-point, but tests sometimes want isolated instances (avoid singleton-shared state across tests). Decision: expose `DVAIBridge.shared` as the primary API, plus a public `DVAIBridge()` initializer for test isolation. Both delegate to the same internal actor.
5. **Audio / vision API surface in the public SDK** — current cores accept image_url / input_audio content parts at the HTTP layer. The Swift API should pass through; no special pre-processing. Documented in §3.2's example. No special API needed beyond the OpenAI-compatible HTTP surface.

## 9. Definition of done

- [ ] `packages/dvai-bridge-ios/` exists and `Package.swift` resolves on Mac.
- [ ] `xcodebuild build -scheme DVAIBridge` succeeds.
- [ ] `xcodebuild test -scheme DVAIBridge` passes, with at least:
  - 8 unit tests covering API shape + backend selector + progress + reactive state + CoreML stub.
  - 1 integration test that boots `DVAIBridge.shared` and hits `/v1/models`.
- [ ] `pod lib lint DVAIBridge.podspec --allow-warnings --use-libraries` passes (or the Swift-only equivalent).
- [ ] `DVAIBridge.shared` exposes the 8-method surface that mirrors the Capacitor JS shim.
- [ ] `BackendKind.coreml` is a valid enum case; the stub throws `notYetImplemented` cleanly.
- [ ] `DVAIBridgeReactiveState` observable updates on lifecycle transitions.
- [ ] `progressPublisher`, `progressStream`, and `addProgressListener` all observe the same broadcast.
- [ ] CI workflow `test-ios-bridge.yml` is green.
- [ ] CHANGELOG entry for `1.8.0` documents the new SDK.
- [ ] Branch merged to main with a clean rebase + fast-forward.
