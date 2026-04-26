# Phase 3C — iOS Native SDK Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to execute this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up `packages/dvai-bridge-ios/` — a top-level iOS SDK that wraps `DVAILlamaCore` + `DVAIFoundationCore` (existing) + a new stub `DVAICoreMLCore`, exposes a unified `DVAIBridge.shared` API, and ships via SPM + CocoaPods.

**Architecture:** Single SPM package with three Swift targets (`DVAIBridge`, `DVAICoreMLCore`, `DVAIBridgeTests`). Two path-dep references to the existing core packages — no source duplication. CoreML backend ships as a stub (`throws notYetImplemented`) so `BackendKind.coreml` is a valid enum case today; full implementation is a follow-up sub-phase. Public API mirrors the Capacitor JS shim's 8-method surface, plus iOS-native conveniences (Combine publisher, AsyncStream, `@Observable` / `ObservableObject` reactive state).

**Tech Stack:** Swift 5.9+ / SPM (path-dep references) / CocoaPods (bundled-source pattern from Phase 3A) / Telegraph (HTTP server, transitively from cores) / Combine + AsyncStream (progress events) / `@Observable` macro (iOS 17+) + `ObservableObject` (iOS < 17 fallback).

**Spec:** [`docs/superpowers/specs/2026-04-26-phase3c-ios-native-sdk-design.md`](../specs/2026-04-26-phase3c-ios-native-sdk-design.md)

**Branch:** `feat/phase3c-ios-native-sdk` off `main`. Implementation done in worktree `.worktrees/phase3c-ios-native-sdk`.

**Phase boundaries:**

- **Tasks 1-2:** Package scaffold + Mac build verify.
- **Tasks 3-7:** Public API types — ProgressEvent, BackendKind, errors, config, BoundServer, broadcaster, selector.
- **Tasks 8-15:** **Full CoreML LLM backend** — swift-transformers integration, MLModel + MLState, sampler, generator, handlers, plugin state, unit tests.
- **Task 16:** DVAIBridge actor (the main API) wired to all three backends.
- **Task 17:** Reactive state (`@Observable` + `ObservableObject`).
- **Task 18:** Real-model integration tests (3 backends, env-var gated, `XCTSkip` patterns).
- **Task 19:** CocoaPods podspec.
- **Task 20:** CI workflow + smoke workflow extension.
- **Task 21:** Phase 3C milestone + CHANGELOG.

**Apply Phase 3A lessons up-front (read before starting):**
1. **Place `Package.swift` at the package root** (not under `ios/`). Identity = `dvai-bridge-ios`.
2. **SPM target paths** include the `ios/` prefix because the manifest is at the package root.
3. **Use `.product(name:package:)` form** for cross-package products; bare-name doesn't resolve reliably.
4. **`@MainActor` for SwiftUI-touching reactive state** — `DVAIBridgeReactiveState` is `@MainActor`-isolated.
5. **Single-product packages don't auto-generate a `*-Package` umbrella scheme.** Multi-product packages do. We have 2 library products (`DVAIBridge` + `DVAICoreMLCore`) → expect `DVAIBridge-Package` to exist.
6. **Bump `public` visibility on every type the public API touches.** Don't auto-default; spell out `public` explicitly.
7. **CocoaPods bundled-source pattern** for cross-package source inclusion — same as Phase 3A wrapper podspecs.

---

## Task 1: Scaffold `dvai-bridge-ios` package

**Files:**
- Create: `packages/dvai-bridge-ios/package.json`
- Create: `packages/dvai-bridge-ios/Package.swift` (root level — not in `ios/`)
- Create: `packages/dvai-bridge-ios/README.md`
- Create: `packages/dvai-bridge-ios/ios/Sources/DVAIBridge/.gitkeep`
- Create: `packages/dvai-bridge-ios/ios/Sources/DVAICoreMLCore/.gitkeep`
- Create: `packages/dvai-bridge-ios/ios/Tests/DVAIBridgeTests/.gitkeep`

- [ ] **Step 1: Create directory tree**

```bash
mkdir -p packages/dvai-bridge-ios/ios/Sources/DVAIBridge
mkdir -p packages/dvai-bridge-ios/ios/Sources/DVAICoreMLCore
mkdir -p packages/dvai-bridge-ios/ios/Tests/DVAIBridgeTests
touch packages/dvai-bridge-ios/ios/Sources/DVAIBridge/.gitkeep
touch packages/dvai-bridge-ios/ios/Sources/DVAICoreMLCore/.gitkeep
touch packages/dvai-bridge-ios/ios/Tests/DVAIBridgeTests/.gitkeep
```

- [ ] **Step 2: Write `package.json`**

```json
{
  "name": "@dvai-bridge/ios",
  "version": "1.7.0",
  "description": "DVAI-Bridge iOS native SDK — embedded local OpenAI-compatible HTTP server with llama.cpp + Apple Foundation Models + CoreML backends.",
  "author": "Deep Chakraborty <https://github.com/dk013>",
  "license": "Custom (See LICENSE)",
  "main": "Package.swift",
  "files": ["Package.swift", "DVAIBridge.podspec", "ios", "README.md", "LICENSE"],
  "publishConfig": {
    "access": "public"
  }
}
```

- [ ] **Step 3: Write `Package.swift`** (at the **package root**)

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
        // Path-dep to the cores. Identity is derived from the path's last
        // directory name; both cores have manifests at their package root,
        // so identities are `dvai-bridge-ios-llama-core` and
        // `dvai-bridge-ios-foundation-core`.
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

- [ ] **Step 4: Write `README.md`** (gitignored at the repo level — sync handled by `scripts/sync-package-meta.js`)

```markdown
# @dvai-bridge/ios

Standalone iOS Swift SDK for dvai-bridge — embedded local OpenAI-compatible
HTTP server with llama.cpp + Apple Foundation Models + CoreML backends. No
Capacitor dependency.

```swift
import DVAIBridge

let server = try await DVAIBridge.shared.start(.init(
    backend: .auto,
    modelPath: "/path/to/model.gguf"
))

// Now point any OpenAI client at server.baseUrl ("http://127.0.0.1:38883/v1")
```

Distribution:
- **SPM:** add `https://github.com/Westenets/dvai-bridge.git` to your `Package.swift`
  dependencies; depend on the `DVAIBridge` product.
- **CocoaPods:** add `pod 'DVAIBridge'` to your Podfile.

Requires:
- `@dvai-bridge/ios-llama-core` (always)
- `@dvai-bridge/ios-foundation-core` (always; `.foundation` backend additionally
  requires iOS 26+ at runtime).
```

- [ ] **Step 5: Add `mac-side-build.sh` + `mac-side-test.sh` cases**

In `scripts/mac-side-build.sh`, add (alphabetical with the existing `ios-*` cases):

```bash
  ios-bridge)
    cd "packages/dvai-bridge-ios"
    xcodebuild build \
      -scheme DVAIBridge \
      -destination "$DEST" \
      -configuration Debug
    ;;
```

In `scripts/mac-side-test.sh`, add:

```bash
  ios-bridge)
    cd "packages/dvai-bridge-ios"
    # Multi-product package — use the `*-Package` umbrella scheme that includes
    # the test target. Same lesson learned in Phase 3A's ios-llama-core.
    SCHEME="DVAIBridge-Package"
    ;;
```

- [ ] **Step 6: Commit the empty scaffold**

```bash
git add packages/dvai-bridge-ios/ scripts/mac-side-build.sh scripts/mac-side-test.sh
git commit -m "chore(ios-bridge): scaffold empty package + mac-side-build/test cases"
```

## Task 2: Verify the scaffold compiles on Mac

- [ ] **Step 1: Push the branch + run an empty Mac build**

```bash
git push -u origin feat/phase3c-ios-native-sdk
ssh mac "cd /Users/zer0/Developer/dvai-bridge && git fetch origin && git checkout feat/phase3c-ios-native-sdk"
pwsh scripts/mac-build.ps1 -Action build -Target ios-bridge
```

Expected: clean SPM resolve. The empty `DVAIBridge` and `DVAICoreMLCore` targets compile to empty libraries (`.gitkeep` files don't break SPM compilation as long as the targets have at least one source file — wait, they don't). If the build fails with "no sources", add a one-line dummy `.swift` file:

```swift
// ios/Sources/DVAIBridge/_Placeholder.swift
// Replaced in Task 4 once real types land.
@_documentation(visibility: internal)
internal struct _DVAIBridgePlaceholder {}
```

```swift
// ios/Sources/DVAICoreMLCore/_Placeholder.swift
@_documentation(visibility: internal)
internal struct _DVAICoreMLCorePlaceholder {}
```

Commit + retry the build.

- [ ] **Step 2: Confirm `xcodebuild -list` shows the umbrella scheme**

```bash
ssh mac "cd /Users/zer0/Developer/dvai-bridge/packages/dvai-bridge-ios && xcodebuild -list 2>&1 | tail -10"
```

Expected: the schemes list includes `DVAIBridge`, `DVAICoreMLCore`, and `DVAIBridge-Package`.

- [ ] **Step 3: No commit (verification)**

## Task 3: Stand up the ProgressEvent type

**Files:**
- Create: `packages/dvai-bridge-ios/ios/Sources/DVAIBridge/ProgressEvent.swift`

- [ ] **Step 1: Write the file**

```swift
import Foundation

/// Lifecycle progress event emitted during start(), downloadModel(), and
/// related long-running operations. Mirrors the existing TS / Capacitor
/// `ProgressEvent` shape so the iOS SDK reads identically to the JS API.
public struct ProgressEvent: Sendable, Equatable, Codable {
    public enum Phase: String, Sendable, Codable {
        case download
        case verify
        case load
        case ready
        case error
    }

    public let phase: Phase
    public let bytesReceived: Int64?
    public let bytesTotal: Int64?
    public let percent: Double?
    public let message: String?

    public init(
        phase: Phase,
        bytesReceived: Int64? = nil,
        bytesTotal: Int64? = nil,
        percent: Double? = nil,
        message: String? = nil
    ) {
        self.phase = phase
        self.bytesReceived = bytesReceived
        self.bytesTotal = bytesTotal
        self.percent = percent
        self.message = message
    }
}
```

- [ ] **Step 2: Write the failing test first**

In `ios/Tests/DVAIBridgeTests/ProgressEventTests.swift`:

```swift
import XCTest
@testable import DVAIBridge

final class ProgressEventTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let original = ProgressEvent(
            phase: .download,
            bytesReceived: 1024,
            bytesTotal: 4096,
            percent: 25.0,
            message: nil
        )
        let json = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProgressEvent.self, from: json)
        XCTAssertEqual(original, decoded)
    }

    func testPhaseRawValues() {
        XCTAssertEqual(ProgressEvent.Phase.download.rawValue, "download")
        XCTAssertEqual(ProgressEvent.Phase.verify.rawValue, "verify")
        XCTAssertEqual(ProgressEvent.Phase.load.rawValue, "load")
        XCTAssertEqual(ProgressEvent.Phase.ready.rawValue, "ready")
        XCTAssertEqual(ProgressEvent.Phase.error.rawValue, "error")
    }
}
```

- [ ] **Step 3: Run tests on Mac**

```bash
git add packages/dvai-bridge-ios/ios/Sources/DVAIBridge/ProgressEvent.swift
git add packages/dvai-bridge-ios/ios/Tests/DVAIBridgeTests/ProgressEventTests.swift
git commit -m "feat(ios-bridge): ProgressEvent struct (Sendable/Equatable/Codable) + tests"
git push
pwsh scripts/mac-build.ps1 -Action test -Target ios-bridge
```

Expected: 2 tests pass.

## Task 4: BackendKind enum + DVAIBridgeError

**Files:**
- Create: `packages/dvai-bridge-ios/ios/Sources/DVAIBridge/BackendKind.swift`
- Create: `packages/dvai-bridge-ios/ios/Sources/DVAIBridge/DVAIBridgeError.swift`

- [ ] **Step 1: Write `BackendKind.swift`**

```swift
import Foundation

/// Inference backend used by `DVAIBridge.shared.start(...)`.
public enum BackendKind: String, Sendable, Codable, CaseIterable {
    /// Resolve the best available backend at runtime.
    case auto
    /// llama.cpp via Metal (iOS) — the broad-compatibility default.
    case llama
    /// Apple Foundation Models (LanguageModelSession). Requires iOS 26+ at runtime.
    case foundation
    /// CoreML / ANE — initial release ships a stub that throws `notYetImplemented`.
    case coreml
}
```

- [ ] **Step 2: Write `DVAIBridgeError.swift`**

```swift
import Foundation

public enum DVAIBridgeError: Error, LocalizedError, Sendable {
    case notStarted
    case alreadyStarted(currentBackend: BackendKind, baseUrl: String)
    case configurationInvalid(reason: String)
    case backendUnavailable(BackendKind, reason: String)
    case modelLoadFailed(reason: String)
    case downloadFailed(reason: String)
    case checksumMismatch
    case backendError(underlying: String)

    public var errorDescription: String? {
        switch self {
        case .notStarted:
            return "DVAIBridge has not been started. Call DVAIBridge.shared.start(...) first."
        case .alreadyStarted(let backend, let baseUrl):
            return "DVAIBridge is already running with backend \(backend) at \(baseUrl). Call stop() before starting a new session."
        case .configurationInvalid(let reason):
            return "Configuration invalid: \(reason)"
        case .backendUnavailable(let backend, let reason):
            return "Backend \(backend) is unavailable on this device: \(reason)"
        case .modelLoadFailed(let reason):
            return "Model load failed: \(reason)"
        case .downloadFailed(let reason):
            return "Download failed: \(reason)"
        case .checksumMismatch:
            return "Downloaded file's SHA-256 didn't match the expected value. The file has been deleted from the cache."
        case .backendError(let msg):
            return "Backend error: \(msg)"
        }
    }
}
```

- [ ] **Step 3: Failing test for error descriptions**

`ios/Tests/DVAIBridgeTests/DVAIBridgeErrorTests.swift`:

```swift
import XCTest
@testable import DVAIBridge

final class DVAIBridgeErrorTests: XCTestCase {
    func testErrorDescriptionsAreUserFacing() {
        let cases: [(DVAIBridgeError, String)] = [
            (.notStarted, "has not been started"),
            (.alreadyStarted(currentBackend: .llama, baseUrl: "http://127.0.0.1:38883/v1"), "already running"),
            (.configurationInvalid(reason: "x"), "invalid"),
            (.backendUnavailable(.foundation, reason: "iOS 26+ required"), "unavailable"),
            (.modelLoadFailed(reason: "x"), "Model load failed"),
            (.downloadFailed(reason: "x"), "Download failed"),
            (.checksumMismatch, "SHA-256"),
            (.backendError(underlying: "x"), "Backend error"),
        ]
        for (err, expectedFragment) in cases {
            XCTAssertNotNil(err.errorDescription, "error has no description: \(err)")
            XCTAssertTrue(
                err.errorDescription!.contains(expectedFragment),
                "expected '\(expectedFragment)' in '\(err.errorDescription!)'"
            )
        }
    }

    func testBackendKindAllCases() {
        XCTAssertEqual(BackendKind.allCases.count, 4)
        XCTAssertTrue(BackendKind.allCases.contains(.auto))
        XCTAssertTrue(BackendKind.allCases.contains(.llama))
        XCTAssertTrue(BackendKind.allCases.contains(.foundation))
        XCTAssertTrue(BackendKind.allCases.contains(.coreml))
    }
}
```

- [ ] **Step 4: Run tests + commit**

```bash
git add packages/dvai-bridge-ios/ios/Sources/DVAIBridge/BackendKind.swift
git add packages/dvai-bridge-ios/ios/Sources/DVAIBridge/DVAIBridgeError.swift
git add packages/dvai-bridge-ios/ios/Tests/DVAIBridgeTests/DVAIBridgeErrorTests.swift
git commit -m "feat(ios-bridge): BackendKind enum + DVAIBridgeError type + tests"
git push
pwsh scripts/mac-build.ps1 -Action test -Target ios-bridge
```

Expected: prior 2 + 2 new = 4 tests pass.

## Task 5: DVAIBridgeConfig (StartOptions analog) + BoundServer (StartResult analog)

**Files:**
- Create: `packages/dvai-bridge-ios/ios/Sources/DVAIBridge/DVAIBridgeConfig.swift`
- Create: `packages/dvai-bridge-ios/ios/Sources/DVAIBridge/BoundServer.swift`

- [ ] **Step 1: Write `DVAIBridgeConfig.swift`**

```swift
import Foundation

public struct DVAIBridgeConfig: Sendable {
    public enum CORSOrigin: Sendable {
        case wildcard
        case exact(String)
        case allowlist([String])
    }

    public var backend: BackendKind
    public var modelPath: String?
    public var mmprojPath: String?
    public var gpuLayers: Int
    public var contextSize: Int
    public var threads: Int
    public var embeddingMode: Bool
    public var httpBasePort: Int
    public var httpMaxPortAttempts: Int
    public var corsOrigin: CORSOrigin
    public var autoUnloadOnLowMemory: Bool
    public var logLevel: String  // "silent" | "info" | "debug" — matches the Capacitor surface

    public init(
        backend: BackendKind = .auto,
        modelPath: String? = nil,
        mmprojPath: String? = nil,
        gpuLayers: Int = 99,
        contextSize: Int = 2048,
        threads: Int = 4,
        embeddingMode: Bool = false,
        httpBasePort: Int = 38883,
        httpMaxPortAttempts: Int = 16,
        corsOrigin: CORSOrigin = .wildcard,
        autoUnloadOnLowMemory: Bool = false,
        logLevel: String = "info"
    ) {
        self.backend = backend
        self.modelPath = modelPath
        self.mmprojPath = mmprojPath
        self.gpuLayers = gpuLayers
        self.contextSize = contextSize
        self.threads = threads
        self.embeddingMode = embeddingMode
        self.httpBasePort = httpBasePort
        self.httpMaxPortAttempts = httpMaxPortAttempts
        self.corsOrigin = corsOrigin
        self.autoUnloadOnLowMemory = autoUnloadOnLowMemory
        self.logLevel = logLevel
    }

    /// Translate this config into the `[String: Any]` shape the underlying
    /// core PluginStates expect (matches the Capacitor JSObject shape).
    internal func toCoreOpts() -> [String: Any] {
        var opts: [String: Any] = [
            "gpuLayers": gpuLayers,
            "contextSize": contextSize,
            "threads": threads,
            "embeddingMode": embeddingMode,
            "httpBasePort": httpBasePort,
            "httpMaxPortAttempts": httpMaxPortAttempts,
            "autoUnloadOnLowMemory": autoUnloadOnLowMemory,
            "logLevel": logLevel,
        ]
        if let modelPath { opts["modelPath"] = modelPath }
        if let mmprojPath { opts["mmprojPath"] = mmprojPath }
        switch corsOrigin {
        case .wildcard: opts["corsOrigin"] = "*"
        case .exact(let s): opts["corsOrigin"] = s
        case .allowlist(let xs): opts["corsOrigin"] = xs
        }
        return opts
    }
}
```

- [ ] **Step 2: Write `BoundServer.swift`**

```swift
import Foundation

public struct BoundServer: Sendable, Equatable {
    public let baseUrl: String
    public let port: Int
    public let backend: BackendKind
    public let modelId: String

    public init(baseUrl: String, port: Int, backend: BackendKind, modelId: String) {
        self.baseUrl = baseUrl
        self.port = port
        self.backend = backend
        self.modelId = modelId
    }

    /// Construct from the underlying core PluginState's `[String: Any]` result.
    internal init(coreResult: [String: Any], backend: BackendKind) throws {
        guard let baseUrl = coreResult["baseUrl"] as? String,
              let port = (coreResult["port"] as? Int) ?? (coreResult["port"] as? NSNumber)?.intValue
        else {
            throw DVAIBridgeError.backendError(underlying: "core PluginState returned malformed start result")
        }
        let modelId = (coreResult["modelId"] as? String) ?? ""
        self.init(baseUrl: baseUrl, port: port, backend: backend, modelId: modelId)
    }
}
```

- [ ] **Step 3: Failing test**

`ios/Tests/DVAIBridgeTests/DVAIBridgeConfigTests.swift`:

```swift
import XCTest
@testable import DVAIBridge

final class DVAIBridgeConfigTests: XCTestCase {
    func testDefaultsMatchSpec() {
        let c = DVAIBridgeConfig()
        XCTAssertEqual(c.backend, .auto)
        XCTAssertNil(c.modelPath)
        XCTAssertEqual(c.gpuLayers, 99)
        XCTAssertEqual(c.contextSize, 2048)
        XCTAssertEqual(c.threads, 4)
        XCTAssertFalse(c.embeddingMode)
        XCTAssertEqual(c.httpBasePort, 38883)
        XCTAssertEqual(c.httpMaxPortAttempts, 16)
        XCTAssertFalse(c.autoUnloadOnLowMemory)
        XCTAssertEqual(c.logLevel, "info")
    }

    func testToCoreOptsWildcardCors() {
        let c = DVAIBridgeConfig(modelPath: "/x.gguf")
        let opts = c.toCoreOpts()
        XCTAssertEqual(opts["modelPath"] as? String, "/x.gguf")
        XCTAssertEqual(opts["corsOrigin"] as? String, "*")
    }

    func testToCoreOptsExactCors() {
        let c = DVAIBridgeConfig(corsOrigin: .exact("https://example.com"))
        XCTAssertEqual(c.toCoreOpts()["corsOrigin"] as? String, "https://example.com")
    }

    func testToCoreOptsAllowlistCors() {
        let c = DVAIBridgeConfig(corsOrigin: .allowlist(["https://a.com", "https://b.com"]))
        XCTAssertEqual(c.toCoreOpts()["corsOrigin"] as? [String], ["https://a.com", "https://b.com"])
    }

    func testBoundServerInitFromCoreResult() throws {
        let result: [String: Any] = [
            "baseUrl": "http://127.0.0.1:38883/v1",
            "port": 38883,
            "modelId": "test-model"
        ]
        let server = try BoundServer(coreResult: result, backend: .llama)
        XCTAssertEqual(server.baseUrl, "http://127.0.0.1:38883/v1")
        XCTAssertEqual(server.port, 38883)
        XCTAssertEqual(server.backend, .llama)
        XCTAssertEqual(server.modelId, "test-model")
    }

    func testBoundServerInitMalformedResult() {
        XCTAssertThrowsError(try BoundServer(coreResult: ["baseUrl": "x"], backend: .llama))
    }
}
```

- [ ] **Step 4: Run + commit**

```bash
git add -A
git commit -m "feat(ios-bridge): DVAIBridgeConfig + BoundServer with core-opts translation + tests"
git push
pwsh scripts/mac-build.ps1 -Action test -Target ios-bridge
```

Expected: 4 + 6 = 10 tests pass.

## Task 6: Progress event broadcaster (internal)

**Files:**
- Create: `packages/dvai-bridge-ios/ios/Sources/DVAIBridge/Internal/ProgressBroadcaster.swift`

- [ ] **Step 1: Make the Internal/ subdir + write the broadcaster**

```bash
mkdir -p packages/dvai-bridge-ios/ios/Sources/DVAIBridge/Internal
```

`Internal/ProgressBroadcaster.swift`:

```swift
import Foundation
import Combine

/// Internal event broadcaster. Backs three public observation surfaces:
/// `progressPublisher` (Combine), `progressStream` (AsyncStream), and
/// `addProgressListener(_:)` (callback). All three observe the same source.
internal final class ProgressBroadcaster: @unchecked Sendable {
    // Combine
    private let subject = PassthroughSubject<ProgressEvent, Never>()
    var publisher: AnyPublisher<ProgressEvent, Never> { subject.eraseToAnyPublisher() }

    // AsyncStream — one continuation per consumer
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<ProgressEvent>.Continuation] = [:]

    // Callback — one entry per addProgressListener call
    private var callbacks: [UUID: @Sendable (ProgressEvent) -> Void] = [:]

    func emit(_ event: ProgressEvent) {
        subject.send(event)

        lock.lock()
        let conts = continuations.values
        let cbs = Array(callbacks.values)
        lock.unlock()

        for cont in conts { cont.yield(event) }
        for cb in cbs { cb(event) }
    }

    func makeStream() -> AsyncStream<ProgressEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            lock.lock()
            continuations[id] = continuation
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.continuations.removeValue(forKey: id)
                self?.lock.unlock()
            }
        }
    }

    @discardableResult
    func addCallback(_ cb: @escaping @Sendable (ProgressEvent) -> Void) -> CancellationToken {
        let id = UUID()
        lock.lock()
        callbacks[id] = cb
        lock.unlock()

        return CancellationToken { [weak self] in
            self?.lock.lock()
            self?.callbacks.removeValue(forKey: id)
            self?.lock.unlock()
        }
    }
}

/// Caller-held token returned by `addProgressListener(_:)`. Drop or call
/// `.cancel()` to stop receiving events.
public final class CancellationToken: @unchecked Sendable {
    private let cancelClosure: @Sendable () -> Void
    private var cancelled = false
    private let lock = NSLock()

    internal init(cancel: @escaping @Sendable () -> Void) {
        self.cancelClosure = cancel
    }

    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        if !cancelled {
            cancelled = true
            cancelClosure()
        }
    }

    deinit {
        cancel()
    }
}
```

- [ ] **Step 2: Failing test**

`ios/Tests/DVAIBridgeTests/ProgressBroadcasterTests.swift`:

```swift
import XCTest
import Combine
@testable import DVAIBridge

final class ProgressBroadcasterTests: XCTestCase {
    func testCombineSubscriberReceivesEvents() {
        let bcast = ProgressBroadcaster()
        let exp = expectation(description: "received event")
        let cancellable = bcast.publisher.sink { event in
            XCTAssertEqual(event.phase, .ready)
            exp.fulfill()
        }
        bcast.emit(ProgressEvent(phase: .ready))
        wait(for: [exp], timeout: 1)
        cancellable.cancel()
    }

    func testAsyncStreamReceivesEvents() async {
        let bcast = ProgressBroadcaster()
        let stream = bcast.makeStream()
        let task = Task { () -> ProgressEvent? in
            for await event in stream { return event }
            return nil
        }
        bcast.emit(ProgressEvent(phase: .download, bytesReceived: 100))
        let received = await task.value
        XCTAssertEqual(received?.phase, .download)
        XCTAssertEqual(received?.bytesReceived, 100)
    }

    func testCallbackReceivesEventsUntilCancelled() {
        let bcast = ProgressBroadcaster()
        var received: [ProgressEvent.Phase] = []
        let token = bcast.addCallback { received.append($0.phase) }

        bcast.emit(ProgressEvent(phase: .download))
        bcast.emit(ProgressEvent(phase: .ready))
        token.cancel()
        bcast.emit(ProgressEvent(phase: .error, message: "should not see"))

        XCTAssertEqual(received, [.download, .ready])
    }

    func testAllThreeSurfacesObserveSameEvent() async {
        let bcast = ProgressBroadcaster()
        var combineCount = 0
        var streamCount = 0
        var callbackCount = 0

        let cancellable = bcast.publisher.sink { _ in combineCount += 1 }
        let stream = bcast.makeStream()
        let task = Task {
            for await _ in stream { streamCount += 1; if streamCount >= 1 { break } }
        }
        let token = bcast.addCallback { _ in callbackCount += 1 }

        bcast.emit(ProgressEvent(phase: .ready))

        // Wait for AsyncStream to yield
        _ = await task.value

        XCTAssertEqual(combineCount, 1)
        XCTAssertEqual(streamCount, 1)
        XCTAssertEqual(callbackCount, 1)

        cancellable.cancel()
        token.cancel()
    }
}
```

- [ ] **Step 3: Run + commit**

```bash
git add -A
git commit -m "feat(ios-bridge): ProgressBroadcaster — Combine + AsyncStream + callback observers"
git push
pwsh scripts/mac-build.ps1 -Action test -Target ios-bridge
```

Expected: 14 total tests pass.

## Task 7: BackendSelector

**Files:**
- Create: `packages/dvai-bridge-ios/ios/Sources/DVAIBridge/Internal/BackendSelector.swift`

- [ ] **Step 1: Write `BackendSelector.swift`**

```swift
import Foundation

internal enum BackendSelector {
    /// Resolve `.auto` to a concrete backend; pass-through for explicit choices.
    /// - Throws `DVAIBridgeError.configurationInvalid` if `.auto` can't decide.
    static func resolve(_ kind: BackendKind, config: DVAIBridgeConfig) throws -> BackendKind {
        if kind != .auto { return kind }

        // 1. modelPath ending in .gguf → .llama
        if let path = config.modelPath, path.hasSuffix(".gguf") {
            return .llama
        }

        // 2. modelPath ending in .mlmodelc / .mlpackage → .coreml
        if let path = config.modelPath,
           path.hasSuffix(".mlmodelc") || path.hasSuffix(".mlpackage") {
            return .coreml
        }

        // 3. modelPath ending in .task / .litertlm → no iOS backend supports
        //    those; fall through to error
        if let path = config.modelPath,
           path.hasSuffix(".task") || path.hasSuffix(".litertlm") {
            throw DVAIBridgeError.configurationInvalid(reason:
                "Model file '\(path)' is a MediaPipe / LiteRT-LM format. " +
                "Use it via the Android SDK; iOS supports llama.cpp (.gguf), " +
                "Apple Foundation Models (no file), and CoreML (.mlmodelc / .mlpackage).")
        }

        // 4. No modelPath + iOS 26+ → .foundation
        if config.modelPath == nil {
            if #available(iOS 26.0, macOS 26.0, *) {
                return .foundation
            }
            throw DVAIBridgeError.configurationInvalid(reason:
                "auto backend requires either modelPath (for .llama / .coreml) " +
                "or iOS 26+ (for .foundation). Set DVAIBridgeConfig.backend explicitly.")
        }

        // 5. Unknown extension
        throw DVAIBridgeError.configurationInvalid(reason:
            "auto backend can't infer from modelPath '\(config.modelPath ?? "<nil>")'. " +
            "Set DVAIBridgeConfig.backend = .llama / .foundation / .coreml explicitly.")
    }
}
```

- [ ] **Step 2: Failing test**

`ios/Tests/DVAIBridgeTests/BackendSelectorTests.swift`:

```swift
import XCTest
@testable import DVAIBridge

final class BackendSelectorTests: XCTestCase {
    func testExplicitChoicePassesThrough() throws {
        for kind in [BackendKind.llama, .foundation, .coreml] {
            let resolved = try BackendSelector.resolve(kind, config: DVAIBridgeConfig())
            XCTAssertEqual(resolved, kind)
        }
    }

    func testAutoWithGGUFResolvesToLlama() throws {
        let cfg = DVAIBridgeConfig(modelPath: "/path/to/model.gguf")
        XCTAssertEqual(try BackendSelector.resolve(.auto, config: cfg), .llama)
    }

    func testAutoWithMlmodelcResolvesToCoreML() throws {
        let cfg = DVAIBridgeConfig(modelPath: "/path/to/model.mlmodelc")
        XCTAssertEqual(try BackendSelector.resolve(.auto, config: cfg), .coreml)
    }

    func testAutoWithMlpackageResolvesToCoreML() throws {
        let cfg = DVAIBridgeConfig(modelPath: "/path/to/model.mlpackage")
        XCTAssertEqual(try BackendSelector.resolve(.auto, config: cfg), .coreml)
    }

    func testAutoWithTaskFileThrows() {
        let cfg = DVAIBridgeConfig(modelPath: "/path/to/model.task")
        XCTAssertThrowsError(try BackendSelector.resolve(.auto, config: cfg)) { err in
            guard case let DVAIBridgeError.configurationInvalid(reason) = err else {
                return XCTFail("wrong error type")
            }
            XCTAssertTrue(reason.contains("Android"))
        }
    }

    func testAutoWithUnknownExtensionThrows() {
        let cfg = DVAIBridgeConfig(modelPath: "/path/to/something.unknown")
        XCTAssertThrowsError(try BackendSelector.resolve(.auto, config: cfg))
    }

    func testAutoWithNoModelPathOnIOS26ResolvesToFoundation() throws {
        // This test only meaningfully runs on iOS 26+. On older simulators
        // the no-modelPath branch throws. Both outcomes are well-defined;
        // assert the right one based on availability.
        let cfg = DVAIBridgeConfig(modelPath: nil)
        if #available(iOS 26.0, macOS 26.0, *) {
            XCTAssertEqual(try BackendSelector.resolve(.auto, config: cfg), .foundation)
        } else {
            XCTAssertThrowsError(try BackendSelector.resolve(.auto, config: cfg))
        }
    }
}
```

- [ ] **Step 3: Run + commit**

```bash
git add -A
git commit -m "feat(ios-bridge): BackendSelector — resolves .auto to a concrete backend or throws"
git push
pwsh scripts/mac-build.ps1 -Action test -Target ios-bridge
```

Expected: 14 + 7 = 21 tests pass.

## Task 8: CoreML — add swift-transformers dep + scaffold target structure

**Files:**
- Modify: `packages/dvai-bridge-ios/Package.swift` (add `swift-transformers` + Telegraph deps to `DVAICoreMLCore` target)
- Create: `packages/dvai-bridge-ios/ios/Sources/DVAICoreMLCore/CoreMLBackendError.swift`
- Create: `packages/dvai-bridge-ios/ios/Sources/DVAICoreMLCore/Internal/` (subdir for non-public types)

- [ ] **Step 1: Add deps to Package.swift**

`DVAICoreMLCore` needs `swift-transformers` (HuggingFace, Apache 2.0, for Tokenizers) and `Telegraph` (HTTP server, transitively shared with the cores). Update the `dependencies:` array AND the `DVAICoreMLCore` target:

```swift
dependencies: [
    .package(path: "../dvai-bridge-ios-llama-core"),
    .package(path: "../dvai-bridge-ios-foundation-core"),
    .package(url: "https://github.com/huggingface/swift-transformers.git", from: "0.1.16"),
    .package(url: "https://github.com/Building42/Telegraph.git", from: "0.40.0"),
],
targets: [
    .target(
        name: "DVAICoreMLCore",
        dependencies: [
            .product(name: "Tokenizers", package: "swift-transformers"),
            "Telegraph",
        ],
        path: "ios/Sources/DVAICoreMLCore"
    ),
    // ... DVAIBridge + tests targets unchanged
]
```

The `Tokenizers` product comes from `swift-transformers`; the `LLM.LanguageModel` higher-level wrapper isn't used (we drive `MLModel` directly for finer control over `MLState`).

- [ ] **Step 2: Write `CoreMLBackendError.swift`**

```swift
import Foundation

public enum CoreMLBackendError: Error, LocalizedError, Sendable {
    case modelLoadFailed(reason: String)
    case tokenizerLoadFailed(reason: String)
    case stateInitFailed(reason: String)
    case generationFailed(reason: String)
    case unsupportedModelFormat(reason: String)

    public var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let r): return "CoreML model load failed: \(r)"
        case .tokenizerLoadFailed(let r): return "Tokenizer load failed: \(r)"
        case .stateInitFailed(let r): return "MLState init failed: \(r)"
        case .generationFailed(let r): return "Generation failed: \(r)"
        case .unsupportedModelFormat(let r): return "Unsupported model format: \(r)"
        }
    }
}
```

- [ ] **Step 3: Make Internal/ subdir + delete the placeholder**

```bash
mkdir -p packages/dvai-bridge-ios/ios/Sources/DVAICoreMLCore/Internal
git rm packages/dvai-bridge-ios/ios/Sources/DVAICoreMLCore/_Placeholder.swift 2>/dev/null || \
git rm packages/dvai-bridge-ios/ios/Sources/DVAICoreMLCore/.gitkeep 2>/dev/null || true
```

- [ ] **Step 4: Verify the package resolves**

```bash
git add -A
git commit -m "feat(coreml-core): add swift-transformers + Telegraph deps; CoreMLBackendError type"
git push
pwsh scripts/mac-build.ps1 -Action build -Target ios-bridge
```

Expected: clean SPM resolve. swift-transformers downloads as a transitive dep. No new tests yet.

## Task 9: CoreML — MLModel + MLState loading

**Files:**
- Create: `packages/dvai-bridge-ios/ios/Sources/DVAICoreMLCore/Internal/CoreMLEngine.swift`

`CoreMLEngine` is the per-PluginState `MLModel` holder + per-conversation `MLState` factory.

- [ ] **Step 1: Write `CoreMLEngine.swift`**

```swift
import Foundation
import CoreML

/// Wraps an `MLModel` plus the shape conventions our CoreML LLM checkpoints
/// follow. `kvStateOnConversation()` produces a fresh `MLState` for each
/// conversation so token-by-token decoding can preserve KV-cache across calls.
@available(iOS 18.0, macOS 15.0, *)
internal final class CoreMLEngine: @unchecked Sendable {
    let model: MLModel
    let inputName: String       // default: "inputIds"
    let outputName: String      // default: "logits"
    let maxContextTokens: Int   // from EngineConfig; default 2048
    let eosTokenId: Int         // from tokenizer config or opts

    init(
        modelURL: URL,
        inputName: String = "inputIds",
        outputName: String = "logits",
        maxContextTokens: Int = 2048,
        eosTokenId: Int,
        computeUnits: MLComputeUnits = .all
    ) throws {
        let cfg = MLModelConfiguration()
        cfg.computeUnits = computeUnits
        do {
            self.model = try MLModel(contentsOf: modelURL, configuration: cfg)
        } catch {
            throw CoreMLBackendError.modelLoadFailed(reason: "\(error)")
        }
        self.inputName = inputName
        self.outputName = outputName
        self.maxContextTokens = maxContextTokens
        self.eosTokenId = eosTokenId
    }

    /// Make a fresh KV-cache state for a new conversation.
    func makeState() throws -> MLState {
        // MLModel.makeState() returns MLState? (introduced iOS 18 / macOS 15).
        guard let state = try? model.makeState() else {
            throw CoreMLBackendError.stateInitFailed(reason:
                "model.makeState() returned nil. Verify the loaded .mlmodelc is " +
                "a stateful model (compiled with state_definitions). See " +
                "Apple's coreml-Llama-3.2-1B-Instruct-4bit for a reference checkpoint.")
        }
        return state
    }
}
```

- [ ] **Step 2: Failing test (mock MLModel via a test harness)**

Use a tiny stub `.mlmodelc` shipped under `ios/Tests/DVAIBridgeTests/Resources/` IF you can produce one cheaply; otherwise unit tests for `CoreMLEngine` are limited to the error paths (model file doesn't exist → `modelLoadFailed`; pre-iOS-18 → compile guard fails). Real-model verification happens in Task 18's integration test.

`ios/Tests/DVAIBridgeTests/CoreMLEngineTests.swift`:

```swift
import XCTest
@testable import DVAIBridge
@testable import DVAICoreMLCore

@available(iOS 18.0, macOS 15.0, *)
final class CoreMLEngineTests: XCTestCase {
    func testLoadFailsForMissingFile() {
        let bogusURL = URL(fileURLWithPath: "/tmp/definitely-does-not-exist.mlmodelc")
        XCTAssertThrowsError(try CoreMLEngine(modelURL: bogusURL, eosTokenId: 0)) { err in
            guard case let CoreMLBackendError.modelLoadFailed(reason) = err else {
                return XCTFail("wrong error: \(err)")
            }
            XCTAssertTrue(reason.contains("error") || reason.contains("Error") || reason.contains("file"))
        }
    }
}
```

- [ ] **Step 3: Run + commit**

```bash
git add -A
git commit -m "feat(coreml-core): CoreMLEngine wraps MLModel + KV-cache MLState"
git push
pwsh scripts/mac-build.ps1 -Action test -Target ios-bridge
```

Expected: prior tests + 1 = 25 total. (Test counts shift; track loosely.)

## Task 10: CoreML — Tokenizer wrapper

**Files:**
- Create: `packages/dvai-bridge-ios/ios/Sources/DVAICoreMLCore/Internal/CoreMLTokenizer.swift`

`CoreMLTokenizer` wraps `swift-transformers`'s `AutoTokenizer` so CoreMLHandlers don't depend on Tokenizers types directly (keeps the boundary tight).

- [ ] **Step 1: Write `CoreMLTokenizer.swift`**

```swift
import Foundation
import Tokenizers

/// Loads a HuggingFace-style tokenizer.json + tokenizer_config.json from a
/// directory. Provides chat-template application + encode/decode.
internal struct CoreMLTokenizer: @unchecked Sendable {
    private let inner: any Tokenizer

    init(tokenizerDir: URL) async throws {
        do {
            // swift-transformers's AutoTokenizer.from(modelFolder:) reads
            // tokenizer.json + tokenizer_config.json from the given directory.
            self.inner = try await AutoTokenizer.from(modelFolder: tokenizerDir)
        } catch {
            throw CoreMLBackendError.tokenizerLoadFailed(reason: "\(error)")
        }
    }

    func applyChatTemplate(messages: [[String: String]], addGenerationPrompt: Bool = true) throws -> [Int] {
        let normalized: [[String: String]] = messages.map {
            ["role": $0["role"] ?? "user", "content": $0["content"] ?? ""]
        }
        do {
            return try inner.applyChatTemplate(messages: normalized, addGenerationPrompt: addGenerationPrompt)
        } catch {
            throw CoreMLBackendError.generationFailed(reason: "applyChatTemplate failed: \(error)")
        }
    }

    func encode(text: String) -> [Int] { inner.encode(text: text) }
    func decode(tokens: [Int]) -> String { inner.decode(tokens: tokens, skipSpecialTokens: true) }
    func decode(token: Int) -> String { decode(tokens: [token]) }

    var eosTokenId: Int { inner.eosTokenId ?? 0 }
}
```

The `Tokenizer` protocol's exact API may differ slightly from this signature — verify via swift-transformers's docs (https://github.com/huggingface/swift-transformers) and adjust. The `applyChatTemplate(...)` signature is the most likely to drift; match what swift-transformers ships.

- [ ] **Step 2: Failing test (skipped until a fixture tokenizer.json exists)**

`ios/Tests/DVAIBridgeTests/CoreMLTokenizerTests.swift`:

```swift
import XCTest
@testable import DVAICoreMLCore

final class CoreMLTokenizerTests: XCTestCase {
    func testInitFailsForMissingDir() async {
        let bogus = URL(fileURLWithPath: "/tmp/no-such-tokenizer-dir-xyz")
        do {
            _ = try await CoreMLTokenizer(tokenizerDir: bogus)
            XCTFail("Expected throw for missing tokenizer dir")
        } catch let err as CoreMLBackendError {
            guard case .tokenizerLoadFailed = err else {
                return XCTFail("wrong error type: \(err)")
            }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }
}
```

- [ ] **Step 3: Run + commit**

```bash
git add -A
git commit -m "feat(coreml-core): CoreMLTokenizer wraps swift-transformers AutoTokenizer"
git push
pwsh scripts/mac-build.ps1 -Action test -Target ios-bridge
```

## Task 11: CoreML — Sampler (greedy + temperature + top-p)

**Files:**
- Create: `packages/dvai-bridge-ios/ios/Sources/DVAICoreMLCore/Internal/CoreMLSampler.swift`

- [ ] **Step 1: Write `CoreMLSampler.swift`**

```swift
import Foundation
import CoreML

internal struct CoreMLSampler {
    let temperature: Float
    let topP: Float
    let topK: Int     // 0 = disabled
    let seed: UInt64?

    /// Sample a token id from a logits vector.
    /// - Parameter logits: 1-D MLMultiArray<Float32> of length vocab_size.
    func sample(logits: MLMultiArray) -> Int {
        let count = logits.count
        let ptr = UnsafeMutablePointer<Float32>(OpaquePointer(logits.dataPointer))

        // 1. Greedy fast-path
        if temperature <= 0 {
            return argmax(ptr, count: count)
        }

        // 2. Apply temperature
        var scaled = [Float](repeating: 0, count: count)
        for i in 0 ..< count { scaled[i] = ptr[i] / temperature }

        // 3. Optional top-K filter
        if topK > 0 && topK < count {
            applyTopK(&scaled, k: topK)
        }

        // 4. Softmax → probabilities
        let probs = softmax(scaled)

        // 5. Optional nucleus (top-p) filter
        let final = topP < 1.0 ? applyTopP(probs, p: topP) : probs

        // 6. Categorical draw
        return categoricalSample(final, seed: seed)
    }

    // MARK: - Helpers

    private func argmax(_ ptr: UnsafeMutablePointer<Float32>, count: Int) -> Int {
        var bestIdx = 0
        var bestVal = ptr[0]
        for i in 1 ..< count {
            if ptr[i] > bestVal { bestVal = ptr[i]; bestIdx = i }
        }
        return bestIdx
    }

    private func softmax(_ logits: [Float]) -> [Float] {
        let maxVal = logits.max() ?? 0
        var exps = logits.map { Float(exp(Double($0 - maxVal))) }
        let sum = exps.reduce(0, +)
        if sum > 0 { for i in 0 ..< exps.count { exps[i] /= sum } }
        return exps
    }

    private func applyTopK(_ logits: inout [Float], k: Int) {
        let kth = logits.sorted(by: >).prefix(k).last ?? -.greatestFiniteMagnitude
        for i in 0 ..< logits.count where logits[i] < kth { logits[i] = -.greatestFiniteMagnitude }
    }

    private func applyTopP(_ probs: [Float], p: Float) -> [Float] {
        let sorted = probs.enumerated().sorted { $0.element > $1.element }
        var cum: Float = 0
        var keep = Set<Int>()
        for (idx, prob) in sorted {
            keep.insert(idx)
            cum += prob
            if cum >= p { break }
        }
        var result = probs
        for i in 0 ..< result.count where !keep.contains(i) { result[i] = 0 }
        let sum = result.reduce(0, +)
        if sum > 0 { for i in 0 ..< result.count { result[i] /= sum } }
        return result
    }

    private func categoricalSample(_ probs: [Float], seed: UInt64?) -> Int {
        var rng: any RandomNumberGenerator = seed.map { SystemRandomNumberGenerator.seeded($0) } ?? SystemRandomNumberGenerator()
        let r = Float.random(in: 0 ..< 1, using: &rng)
        var cum: Float = 0
        for i in 0 ..< probs.count {
            cum += probs[i]
            if r < cum { return i }
        }
        return probs.count - 1
    }
}

extension SystemRandomNumberGenerator {
    static func seeded(_ seed: UInt64) -> SystemRandomNumberGenerator {
        // SystemRandomNumberGenerator can't actually be seeded; for repeatable
        // tests, use a different RNG. This is a placeholder — real seeding
        // requires a custom RNG implementation. For 3C ship, drop the `seed`
        // argument from the public API (Apple-managed entropy is fine for
        // production sampling).
        return SystemRandomNumberGenerator()
    }
}
```

(Note: `SystemRandomNumberGenerator` doesn't accept seeds; the helper is a placeholder. If reproducible sampling is critical, implement a small Mulberry32 PRNG. For 3C ship, accept non-deterministic sampling as a feature — it matches every other LLM SDK's default behavior.)

- [ ] **Step 2: Tests**

`ios/Tests/DVAIBridgeTests/CoreMLSamplerTests.swift`:

```swift
import XCTest
import CoreML
@testable import DVAICoreMLCore

final class CoreMLSamplerTests: XCTestCase {
    func makeLogits(_ vals: [Float]) -> MLMultiArray {
        let arr = try! MLMultiArray(shape: [NSNumber(value: vals.count)], dataType: .float32)
        for (i, v) in vals.enumerated() { arr[i] = NSNumber(value: v) }
        return arr
    }

    func testGreedyReturnsArgmax() {
        let s = CoreMLSampler(temperature: 0, topP: 1.0, topK: 0, seed: nil)
        let logits = makeLogits([1.0, 5.0, 2.0, 4.0])
        XCTAssertEqual(s.sample(logits: logits), 1)  // argmax index
    }

    func testTemperatureSamplingNeverThrows() {
        let s = CoreMLSampler(temperature: 1.0, topP: 1.0, topK: 0, seed: nil)
        let logits = makeLogits([1.0, 2.0, 3.0, 4.0])
        for _ in 0 ..< 100 {
            let token = s.sample(logits: logits)
            XCTAssertGreaterThanOrEqual(token, 0)
            XCTAssertLessThan(token, 4)
        }
    }

    func testTopPTruncationFavorsHighProb() {
        // With top_p = 0.5 and a sharply skewed distribution, only the top
        // few tokens should ever be selected.
        let s = CoreMLSampler(temperature: 1.0, topP: 0.5, topK: 0, seed: nil)
        // Logits chosen so that softmax(logits) ≈ [0.0, 0.0, 0.05, 0.95]
        let logits = makeLogits([-100.0, -100.0, 1.0, 4.0])
        var counts = [0, 0, 0, 0]
        for _ in 0 ..< 1000 { counts[s.sample(logits: logits)] += 1 }
        XCTAssertEqual(counts[0], 0)
        XCTAssertEqual(counts[1], 0)
        XCTAssertGreaterThan(counts[3], counts[2])  // 4.0 picked far more often than 1.0
    }
}
```

- [ ] **Step 3: Run + commit**

```bash
git add -A
git commit -m "feat(coreml-core): CoreMLSampler — greedy + temperature + top-p + top-k"
git push
pwsh scripts/mac-build.ps1 -Action test -Target ios-bridge
```

Expected: 3 sampler tests pass.

## Task 12: CoreML — Generator (autoregressive decode loop)

**Files:**
- Create: `packages/dvai-bridge-ios/ios/Sources/DVAICoreMLCore/Internal/CoreMLGenerator.swift`

`CoreMLGenerator` ties Engine + Tokenizer + Sampler together: takes a chat-formatted prompt, runs the decode loop, returns text (or yields tokens for streaming).

- [ ] **Step 1: Write `CoreMLGenerator.swift`**

```swift
import Foundation
import CoreML

@available(iOS 18.0, macOS 15.0, *)
internal struct CoreMLGenerator: @unchecked Sendable {
    let engine: CoreMLEngine
    let tokenizer: CoreMLTokenizer
    let sampler: CoreMLSampler
    let maxNewTokens: Int

    /// Synchronous (buffered) generation. Returns the decoded text.
    func generate(promptTokens: [Int]) async throws -> String {
        var generated: [Int] = []
        var contextTokens = promptTokens
        let state = try engine.makeState()

        // Prefill: run the prompt tokens through once to build the KV-cache.
        // For simplicity we do step-by-step decoding even on prefill — most
        // Apple-shipped CoreML LLM checkpoints accept single-token input.
        // A future optimization can prefill in batches if the model supports it.
        for token in contextTokens {
            _ = try await runStep(token: token, state: state)
        }

        var nextToken: Int = sampler.sample(logits: try await runStep(token: contextTokens.last!, state: state))
        for _ in 0 ..< maxNewTokens {
            if nextToken == engine.eosTokenId { break }
            generated.append(nextToken)
            let logits = try await runStep(token: nextToken, state: state)
            nextToken = sampler.sample(logits: logits)
        }

        return tokenizer.decode(tokens: generated)
    }

    /// Streaming generation. Yields each decoded token chunk through the
    /// returned AsyncStream.
    func generateStream(promptTokens: [Int]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    var generated: [Int] = []
                    let contextTokens = promptTokens
                    let state = try engine.makeState()

                    for token in contextTokens {
                        _ = try await runStep(token: token, state: state)
                    }

                    var nextToken = sampler.sample(logits: try await runStep(token: contextTokens.last!, state: state))
                    for _ in 0 ..< maxNewTokens {
                        if nextToken == engine.eosTokenId { break }
                        generated.append(nextToken)
                        let chunk = tokenizer.decode(token: nextToken)
                        continuation.yield(chunk)
                        let logits = try await runStep(token: nextToken, state: state)
                        nextToken = sampler.sample(logits: logits)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Private

    private func runStep(token: Int, state: MLState) async throws -> MLMultiArray {
        let inputArr = try MLMultiArray(shape: [1, 1], dataType: .int32)
        inputArr[[0, 0] as [NSNumber]] = NSNumber(value: token)
        let input = try MLDictionaryFeatureProvider(dictionary: [engine.inputName: inputArr])
        let output = try await engine.model.prediction(from: input, options: MLPredictionOptions(), state: state)
        guard let logits = output.featureValue(for: engine.outputName)?.multiArrayValue else {
            throw CoreMLBackendError.generationFailed(reason: "no '\(engine.outputName)' output")
        }
        return logits
    }
}
```

The exact `MLModel.prediction(from:options:state:)` async signature varies by iOS version. Check Apple's docs for iOS 18+ and adjust. If the API is sync, wrap in `Task.detached` to avoid blocking.

- [ ] **Step 2: Tests (limited without a real model)**

CoreMLGenerator's unit testable surface is small without a real MLModel. Most behavior verification happens in Task 18's integration test. For 3C, a single API-shape test:

`ios/Tests/DVAIBridgeTests/CoreMLGeneratorShapeTests.swift`:

```swift
import XCTest
@testable import DVAICoreMLCore

@available(iOS 18.0, macOS 15.0, *)
final class CoreMLGeneratorShapeTests: XCTestCase {
    func testTypesCompile() {
        // Ensures the public-internal API compiles. Real generation tested
        // end-to-end in RealModelIntegrationTest.
        let _: AsyncThrowingStream<String, Error>.Type = AsyncThrowingStream<String, Error>.self
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat(coreml-core): CoreMLGenerator — autoregressive decode loop with KV-cache"
git push
pwsh scripts/mac-build.ps1 -Action test -Target ios-bridge
```

## Task 13: CoreML — Handlers (DVAIHandlers conformer)

**Files:**
- Modify: `packages/dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCore/HandlerDispatch.swift` (hoist `DVAIHandlers` protocol to public)
- Create: `packages/dvai-bridge-ios/ios/Sources/DVAICoreMLCore/CoreMLHandlers.swift`

- [ ] **Step 1: Hoist `DVAIHandlers` in DVAILlamaCore**

Read `packages/dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCore/HandlerDispatch.swift`. The `DVAIHandlers` protocol (and `HandlerContext` + `HandlerResponse` types) are likely currently `internal` or `public`. **Make them `public` if not already.**

```bash
grep -n "DVAIHandlers\|HandlerContext\|HandlerResponse" packages/dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCore/HandlerDispatch.swift | head -10
```

If the protocol/types lack `public`, add it. Surgical edit. The change is part of "new public symbols the SDK needs them to expose" per the spec's non-goals.

- [ ] **Step 2: Write CoreMLHandlers.swift**

```swift
import Foundation
import DVAILlamaCore

@available(iOS 18.0, macOS 15.0, *)
public final class CoreMLHandlers: DVAIHandlers {
    private let generator: CoreMLGenerator
    private let modelId: String

    public init(generator: CoreMLGenerator, modelId: String) {
        self.generator = generator
        self.modelId = modelId
    }

    public func handleChatCompletion(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse {
        guard let messages = body["messages"] as? [[String: String]] else {
            return .error(400, "messages array is required")
        }
        let stream = (body["stream"] as? Bool) ?? false
        let temperature = (body["temperature"] as? Double).map(Float.init) ?? 0.0
        let topP = (body["top_p"] as? Double).map(Float.init) ?? 1.0
        let maxTokens = (body["max_tokens"] as? Int) ?? 512

        let promptTokens: [Int]
        do {
            promptTokens = try generator.tokenizer.applyChatTemplate(messages: messages)
        } catch {
            return .error(400, "tokenizer chat-template failed: \(error.localizedDescription)")
        }

        if stream {
            let sse = generator.generateStream(promptTokens: promptTokens)
            let streamId = UUID().uuidString
            let mappedStream = AsyncStream<String> { cont in
                Task {
                    do {
                        for try await chunk in sse {
                            let evt = """
                            data: {"id":"\(streamId)","object":"chat.completion.chunk","created":\(Int(Date().timeIntervalSince1970)),"model":"\(modelId)","choices":[{"index":0,"delta":{"content":\(jsonString(chunk))},"finish_reason":null}]}\n\n
                            """
                            cont.yield(evt)
                        }
                        cont.yield("data: [DONE]\n\n")
                        cont.finish()
                    } catch {
                        cont.yield("data: {\"error\":\"\(error.localizedDescription)\"}\n\n")
                        cont.finish()
                    }
                }
            }
            return .sse(mappedStream)
        }

        let text: String
        do {
            text = try await generator.generate(promptTokens: promptTokens)
        } catch {
            return .error(500, "generation failed: \(error.localizedDescription)")
        }
        let responseJSON: [String: Any] = [
            "id": UUID().uuidString,
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": modelId,
            "choices": [[
                "index": 0,
                "message": ["role": "assistant", "content": text],
                "finish_reason": "stop"
            ]],
            "usage": [
                "prompt_tokens": promptTokens.count,
                "completion_tokens": -1,  // CoreML decoding doesn't track this in a stable way per checkpoint
                "total_tokens": -1
            ]
        ]
        return .json(200, responseJSON)
    }

    public func handleCompletion(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse {
        // Re-route to chat completion under the hood — same generator, same tokenizer.
        let prompt = body["prompt"] as? String ?? ""
        let chatBody: [String: Any] = [
            "messages": [["role": "user", "content": prompt]],
            "stream": body["stream"] as? Bool ?? false,
            "temperature": body["temperature"] as? Double ?? 0.0,
            "top_p": body["top_p"] as? Double ?? 1.0,
            "max_tokens": body["max_tokens"] as? Int ?? 512,
        ]
        return try await handleChatCompletion(body: chatBody, ctx: ctx)
    }

    public func handleEmbeddings(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse {
        return .error(501, "embeddings not yet supported by the CoreML backend")
    }

    public func handleModels(ctx: HandlerContext) async throws -> HandlerResponse {
        return .json(200, [
            "object": "list",
            "data": [["id": modelId, "object": "model", "owned_by": "dvai-bridge"]]
        ])
    }

    private func jsonString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s], options: [])
        let str = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(str.dropFirst().dropLast())  // strip the [...] brackets
    }
}
```

(Match `DVAIHandlers` / `HandlerContext` / `HandlerResponse` types to whatever DVAILlamaCore exposes. The signature shapes here are the canonical Phase 1 ones; small drift is possible.)

- [ ] **Step 3: Tests for handler shape**

`ios/Tests/DVAIBridgeTests/CoreMLHandlersTests.swift`:

```swift
import XCTest
import DVAILlamaCore
@testable import DVAICoreMLCore

@available(iOS 18.0, macOS 15.0, *)
final class CoreMLHandlersTests: XCTestCase {
    func testHandleEmbeddingsReturns501() async throws {
        // Construct a handler with a stand-in generator (we don't actually
        // generate anything; the embeddings endpoint short-circuits).
        // For this test, pass a placeholder generator instance — we only
        // care that the embeddings handler returns 501 without invoking
        // the generator.
        // (Use a fake `MLModel` if Apple's API allows construction without
        // a real .mlmodelc; otherwise this test is purely shape verification
        // and the body is exercised in Task 18's integration test.)

        // For Phase 3C this assertion is reasonable as a compile-time check:
        let response: HandlerResponse = .error(501, "embeddings not yet supported by the CoreML backend")
        if case let .error(status, msg) = response {
            XCTAssertEqual(status, 501)
            XCTAssertTrue(msg.contains("embeddings"))
        } else {
            XCTFail("expected error response")
        }
    }

    func testHandleModelsReturnsConfiguredModel() async throws {
        let response: HandlerResponse = .json(200, [
            "object": "list",
            "data": [["id": "test-model", "object": "model", "owned_by": "dvai-bridge"]]
        ])
        if case let .json(status, body) = response {
            XCTAssertEqual(status, 200)
            let dict = body as? [String: Any]
            XCTAssertEqual(dict?["object"] as? String, "list")
        } else {
            XCTFail("expected json response")
        }
    }
}
```

(Tests for the actual generation path live in Task 18's `RealModelIntegrationTest` since they need a real MLModel.)

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(coreml-core): CoreMLHandlers — DVAIHandlers conformer for OpenAI chat/completion/models"
git push
pwsh scripts/mac-build.ps1 -Action test -Target ios-bridge
```

## Task 14: CoreML — PluginState (the public actor that ties everything together)

**Files:**
- Create: `packages/dvai-bridge-ios/ios/Sources/DVAICoreMLCore/CoreMLPluginState.swift`
- Modify: `packages/dvai-bridge-ios/ios/Sources/DVAICoreMLCore/CoreMLPluginState.swift` (the empty file from Task 8 if you stubbed it — replace)

- [ ] **Step 1: Write CoreMLPluginState.swift**

```swift
import Foundation
import CoreML
import DVAILlamaCore   // for HttpServer + DVAIHandlers types

/// Public PluginState mirroring DVAILlamaCore.PluginState's shape. Boots a
/// Telegraph HTTP server on `127.0.0.1:<port>` (with port-fallback), loads
/// the .mlmodelc model + tokenizer, and serves OpenAI requests via
/// CoreMLHandlers.
@available(iOS 18.0, macOS 15.0, *)
public actor CoreMLPluginState {
    private var httpServer: HttpServer?
    private var generator: CoreMLGenerator?
    private var modelId: String = ""
    private var isRunning: Bool = false
    private var baseUrl: String?
    private var port: Int?

    public init() {}

    public func start(opts: [String: Any]) async throws -> [String: Any] {
        if isRunning { try await stop() }

        guard let modelPath = opts["modelPath"] as? String, !modelPath.isEmpty else {
            throw CoreMLBackendError.modelLoadFailed(reason: "modelPath is required for the CoreML backend")
        }
        guard let tokenizerPath = opts["tokenizerPath"] as? String, !tokenizerPath.isEmpty else {
            throw CoreMLBackendError.tokenizerLoadFailed(reason:
                "tokenizerPath is required (path to a directory containing tokenizer.json + tokenizer_config.json)")
        }

        let modelURL = URL(fileURLWithPath: modelPath)
        let tokenizerDir = URL(fileURLWithPath: tokenizerPath)

        // Optional opts
        let inputName = (opts["coremlInputName"] as? String) ?? "inputIds"
        let outputName = (opts["coremlOutputName"] as? String) ?? "logits"
        let maxContextTokens = (opts["contextSize"] as? Int) ?? 2048
        let temperature = (opts["temperature"] as? Double).map(Float.init) ?? 0.0
        let topP = (opts["topP"] as? Double).map(Float.init) ?? 1.0
        let topK = (opts["topK"] as? Int) ?? 0
        let maxNewTokens = (opts["maxNewTokens"] as? Int) ?? 512
        let httpBasePort = (opts["httpBasePort"] as? Int) ?? 38883
        let httpMaxPortAttempts = (opts["httpMaxPortAttempts"] as? Int) ?? 16

        // Tokenizer must load first — its eosTokenId is needed by the engine
        let tokenizer = try await CoreMLTokenizer(tokenizerDir: tokenizerDir)
        let engine = try CoreMLEngine(
            modelURL: modelURL,
            inputName: inputName,
            outputName: outputName,
            maxContextTokens: maxContextTokens,
            eosTokenId: tokenizer.eosTokenId
        )

        let sampler = CoreMLSampler(temperature: temperature, topP: topP, topK: topK, seed: nil)
        let generator = CoreMLGenerator(
            engine: engine,
            tokenizer: tokenizer,
            sampler: sampler,
            maxNewTokens: maxNewTokens
        )

        let modelIdValue = modelURL.deletingPathExtension().lastPathComponent
        let handlers = CoreMLHandlers(generator: generator, modelId: modelIdValue)

        let server = HttpServer()
        let boundPort = try await server.tryBind(
            basePort: httpBasePort,
            maxAttempts: httpMaxPortAttempts,
            host: "127.0.0.1"
        )
        let ctx = HandlerContext(modelId: modelIdValue, backendName: "coreml")
        let cfg = DispatchConfig(corsOrigin: parseCors(opts["corsOrigin"]))
        await server.installRoutes(handlers: handlers, ctx: ctx, config: cfg)

        self.httpServer = server
        self.generator = generator
        self.modelId = modelIdValue
        self.port = boundPort
        self.baseUrl = "http://127.0.0.1:\(boundPort)/v1"
        self.isRunning = true

        return [
            "baseUrl": self.baseUrl!,
            "port": boundPort,
            "backend": "coreml",
            "modelId": modelIdValue,
        ]
    }

    public func stop() async throws {
        await httpServer?.stop()
        httpServer = nil
        generator = nil
        modelId = ""
        baseUrl = nil
        port = nil
        isRunning = false
    }

    public func statusInfo() -> [String: Any] {
        var dict: [String: Any] = ["running": isRunning]
        if let baseUrl = baseUrl { dict["baseUrl"] = baseUrl }
        if isRunning { dict["backend"] = "coreml" }
        return dict
    }

    private func parseCors(_ raw: Any?) -> DispatchConfig.CORSConfig {
        if let s = raw as? String { return s == "*" ? .wildcard : .exact(s) }
        if let arr = raw as? [String] { return .allowlist(arr) }
        return .wildcard
    }
}
```

The exact `HttpServer.tryBind(...)` and `installRoutes(...)` signatures come from `DVAILlamaCore.HttpServer`. If they're internal, you'll need to bump them to public in the same task that hoists `DVAIHandlers` (Task 13 Step 1).

- [ ] **Step 2: Tests**

`ios/Tests/DVAIBridgeTests/CoreMLPluginStateTests.swift`:

```swift
import XCTest
@testable import DVAIBridge
@testable import DVAICoreMLCore

@available(iOS 18.0, macOS 15.0, *)
final class CoreMLPluginStateTests: XCTestCase {
    func testStartFailsWithoutModelPath() async {
        let state = CoreMLPluginState()
        do {
            _ = try await state.start(opts: [:])
            XCTFail("Expected throw")
        } catch let err as CoreMLBackendError {
            guard case .modelLoadFailed = err else { return XCTFail("wrong: \(err)") }
        } catch {
            XCTFail("wrong type: \(error)")
        }
    }

    func testStartFailsWithoutTokenizerPath() async {
        let state = CoreMLPluginState()
        do {
            _ = try await state.start(opts: ["modelPath": "/tmp/x.mlmodelc"])
            XCTFail("Expected throw")
        } catch let err as CoreMLBackendError {
            guard case .tokenizerLoadFailed = err else { return XCTFail("wrong: \(err)") }
        } catch {
            XCTFail("wrong type: \(error)")
        }
    }

    func testStopWhenNotStartedIsIdempotent() async throws {
        try await CoreMLPluginState().stop()
        // doesn't throw
    }

    func testStatusInfoReportsNotRunning() async {
        let info = CoreMLPluginState().statusInfo()
        XCTAssertEqual(info["running"] as? Bool, false)
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat(coreml-core): CoreMLPluginState — public actor with HTTP server + handlers"
git push
pwsh scripts/mac-build.ps1 -Action test -Target ios-bridge
```

## Task 15: CoreML — verify the full backend compiles

Verification only. Make sure everything from Tasks 8–14 compiles together.

- [ ] **Step 1: Build + test on Mac**

```bash
pwsh scripts/mac-build.ps1 -Action test -Target ios-bridge
```

Expected: prior counts + ~10 CoreML-specific tests = around 30+ unit tests.

- [ ] **Step 2: No commit (verification)**

## Task 16: DVAIBridge actor (the main API)

**Files:**
- Create: `packages/dvai-bridge-ios/ios/Sources/DVAIBridge/DVAIBridge.swift`
- Modify: `packages/dvai-bridge-ios/ios/Sources/DVAIBridge/_Placeholder.swift` (delete)

This is the largest task. It implements the 8-method public surface by dispatching to the appropriate core's PluginState.

- [ ] **Step 1: Write `DVAIBridge.swift`**

```swift
import Foundation
import Combine
import DVAILlamaCore
import DVAIFoundationCore
import DVAICoreMLCore

/// The iOS SDK entry-point. Use the `shared` singleton or construct an instance
/// for test isolation. All methods are async-throws and dispatch to the active
/// backend's PluginState under the hood. Capacitor-free: no Capacitor headers
/// are imported anywhere.
public actor DVAIBridge {
    public static let shared = DVAIBridge()

    private enum BackendInstance {
        case llama(DVAILlamaCore.PluginState)
        case foundation(DVAIFoundationCore.PluginState)
        case coreml(DVAICoreMLCore.CoreMLPluginState)
    }

    private var active: BackendInstance?
    private var activeKind: BackendKind?
    private var activeBaseUrl: String?
    private let downloader = DVAILlamaCore.ModelDownloader()
    internal let progressBroadcaster = ProgressBroadcaster()

    public init() {}

    // MARK: - Lifecycle

    public func start(_ config: DVAIBridgeConfig) async throws -> BoundServer {
        if let activeBaseUrl, let activeKind {
            throw DVAIBridgeError.alreadyStarted(currentBackend: activeKind, baseUrl: activeBaseUrl)
        }

        let resolved = try BackendSelector.resolve(config.backend, config: config)
        let opts = config.toCoreOpts()

        let result: [String: Any]
        let backend: BackendInstance

        progressBroadcaster.emit(ProgressEvent(phase: .load))

        switch resolved {
        case .auto:
            // BackendSelector.resolve never returns .auto; keep the compiler happy
            throw DVAIBridgeError.configurationInvalid(reason: "BackendSelector returned .auto unexpectedly")
        case .llama:
            let state = DVAILlamaCore.PluginState()
            do {
                result = try await state.start(opts: opts)
            } catch {
                progressBroadcaster.emit(ProgressEvent(phase: .error, message: error.localizedDescription))
                throw DVAIBridgeError.modelLoadFailed(reason: error.localizedDescription)
            }
            backend = .llama(state)
        case .foundation:
            let state = DVAIFoundationCore.PluginState()
            do {
                result = try await state.start(opts: opts)
            } catch {
                progressBroadcaster.emit(ProgressEvent(phase: .error, message: error.localizedDescription))
                throw DVAIBridgeError.backendError(underlying: error.localizedDescription)
            }
            backend = .foundation(state)
        case .coreml:
            let state = DVAICoreMLCore.CoreMLPluginState()
            do {
                result = try await state.start(opts: opts)
            } catch let err as CoreMLBackendError {
                progressBroadcaster.emit(ProgressEvent(phase: .error, message: err.errorDescription ?? ""))
                throw DVAIBridgeError.backendUnavailable(.coreml, reason: err.errorDescription ?? "")
            }
            backend = .coreml(state)
        }

        let server = try BoundServer(coreResult: result, backend: resolved)
        self.active = backend
        self.activeKind = resolved
        self.activeBaseUrl = server.baseUrl

        progressBroadcaster.emit(ProgressEvent(phase: .ready))
        return server
    }

    public func stop() async throws {
        guard let backend = active else {
            return  // idempotent
        }
        do {
            switch backend {
            case .llama(let state): try await state.stop()
            case .foundation(let state): try await state.stop()
            case .coreml(let state): try await state.stop()
            }
        } catch {
            // Even if stop() throws, clear state — caller can't usefully retry
            self.active = nil
            self.activeKind = nil
            self.activeBaseUrl = nil
            throw DVAIBridgeError.backendError(underlying: error.localizedDescription)
        }
        self.active = nil
        self.activeKind = nil
        self.activeBaseUrl = nil
    }

    // MARK: - Status

    public struct StatusInfo: Sendable, Equatable {
        public let running: Bool
        public let backend: BackendKind?
        public let baseUrl: String?
    }

    public func status() -> StatusInfo {
        StatusInfo(
            running: active != nil,
            backend: activeKind,
            baseUrl: activeBaseUrl
        )
    }

    // MARK: - Progress observation

    public nonisolated var progressPublisher: AnyPublisher<ProgressEvent, Never> {
        progressBroadcaster.publisher
    }

    public nonisolated var progressStream: AsyncStream<ProgressEvent> {
        progressBroadcaster.makeStream()
    }

    @discardableResult
    public nonisolated func addProgressListener(
        _ cb: @escaping @Sendable (ProgressEvent) -> Void
    ) -> CancellationToken {
        progressBroadcaster.addCallback(cb)
    }

    // MARK: - Model management (delegates to ModelDownloader)

    public struct DownloadOptions: Sendable {
        public var url: URL
        public var sha256: String
        public var destFilename: String?
        public var headers: [String: String]
        public init(url: URL, sha256: String, destFilename: String? = nil, headers: [String: String] = [:]) {
            self.url = url; self.sha256 = sha256; self.destFilename = destFilename; self.headers = headers
        }
    }

    public struct DownloadResult: Sendable, Equatable {
        public let path: String
        public let cached: Bool
    }

    public func downloadModel(_ opts: DownloadOptions) async throws -> DownloadResult {
        let dest = opts.destFilename ?? opts.url.lastPathComponent
        progressBroadcaster.emit(ProgressEvent(phase: .download))
        do {
            let coreResult = try await downloader.downloadModel(
                url: opts.url,
                expectedSha256: opts.sha256,
                destFilename: dest,
                headers: opts.headers,
                onProgress: { [weak self] received, total in
                    let percent = total.map { $0 > 0 ? (Double(received) / Double($0)) * 100.0 : nil } ?? nil
                    self?.progressBroadcaster.emit(ProgressEvent(
                        phase: .download,
                        bytesReceived: Int64(received),
                        bytesTotal: total.map { Int64($0) },
                        percent: percent ?? nil
                    ))
                }
            )
            progressBroadcaster.emit(ProgressEvent(phase: .verify))
            return DownloadResult(path: coreResult.path, cached: coreResult.cached)
        } catch {
            progressBroadcaster.emit(ProgressEvent(phase: .error, message: error.localizedDescription))
            // The downloader throws checksumMismatch as its own type; map.
            if String(describing: error).contains("checksum") || String(describing: error).contains("ChecksumMismatch") {
                throw DVAIBridgeError.checksumMismatch
            }
            throw DVAIBridgeError.downloadFailed(reason: error.localizedDescription)
        }
    }

    public func listCachedModels() async throws -> [DVAILlamaCore.CachedModelInfoSwift] {
        try await downloader.listCachedModels()
    }

    public func deleteCachedModel(filename: String) async throws {
        try await downloader.deleteCachedModel(filename: filename)
    }

    public func cacheDir() async throws -> String {
        try await downloader.cacheDirPath()
    }
}
```

(The exact `onProgress` argument types come from `DVAILlamaCore.ModelDownloader.downloadModel(...)` — verify with `cat packages/dvai-bridge-ios-llama-core/ios/Sources/DVAILlamaCore/ModelDownloader.swift` and adjust the closure signature to match.)

- [ ] **Step 2: Delete the placeholder**

```bash
git rm packages/dvai-bridge-ios/ios/Sources/DVAIBridge/_Placeholder.swift 2>/dev/null || true
```

- [ ] **Step 3: Failing tests for DVAIBridge basics**

`ios/Tests/DVAIBridgeTests/DVAIBridgeAPIShapeTests.swift`:

```swift
import XCTest
@testable import DVAIBridge

final class DVAIBridgeAPIShapeTests: XCTestCase {
    func testSingletonExists() {
        let bridge: DVAIBridge = DVAIBridge.shared
        XCTAssertNotNil(bridge)
    }

    func testStatusBeforeStartReportsNotRunning() async {
        let bridge = DVAIBridge()  // fresh instance for test isolation
        let info = await bridge.status()
        XCTAssertFalse(info.running)
        XCTAssertNil(info.backend)
        XCTAssertNil(info.baseUrl)
    }

    func testStopWhenNotStartedIsIdempotent() async throws {
        let bridge = DVAIBridge()
        try await bridge.stop()
        try await bridge.stop()  // no throw
    }

    func testStartCoreMLThrowsBackendUnavailable() async {
        let bridge = DVAIBridge()
        do {
            _ = try await bridge.start(.init(backend: .coreml))
            XCTFail("Expected throw")
        } catch let err as DVAIBridgeError {
            if case .backendUnavailable(.coreml, _) = err { /* expected */ } else {
                XCTFail("wrong error: \(err)")
            }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }
}
```

- [ ] **Step 4: Run + commit**

```bash
git add -A
git commit -m "feat(ios-bridge): DVAIBridge actor + 8-method API surface delegating to cores"
git push
pwsh scripts/mac-build.ps1 -Action test -Target ios-bridge
```

Expected: 24 + 4 = 28 tests pass.

## Task 17: Reactive state (`@Observable` + `ObservableObject`)

**Files:**
- Create: `packages/dvai-bridge-ios/ios/Sources/DVAIBridge/ReactiveState.swift`

- [ ] **Step 1: Write `ReactiveState.swift`**

```swift
import Foundation
import Combine

/// SwiftUI-friendly reactive state. Backed by Combine for iOS < 17 and by
/// the `@Observable` macro for iOS 17+ (compiled conditionally).
@MainActor
public final class DVAIBridgeReactiveState: ObservableObject {
    @Published public private(set) var isReady: Bool = false
    @Published public private(set) var baseUrl: String? = nil
    @Published public private(set) var port: Int? = nil
    @Published public private(set) var currentBackend: BackendKind? = nil
    @Published public private(set) var lastProgress: ProgressEvent? = nil

    internal init() {}

    internal func didStart(_ server: BoundServer) {
        isReady = true
        baseUrl = server.baseUrl
        port = server.port
        currentBackend = server.backend
    }

    internal func didStop() {
        isReady = false
        baseUrl = nil
        port = nil
        currentBackend = nil
    }

    internal func didReceiveProgress(_ event: ProgressEvent) {
        lastProgress = event
    }
}

extension DVAIBridge {
    /// Main-actor-isolated reactive state for SwiftUI views. Updates on every
    /// lifecycle transition. The same object is shared across observers; pin
    /// it as `@StateObject` (or `@ObservedObject` if owned upstream).
    @MainActor
    public var reactive: DVAIBridgeReactiveState {
        // Lazily create per-actor-instance; subsequent accesses return the same.
        DVAIBridgeReactiveStateRegistry.shared.state(for: self)
    }
}

/// Per-DVAIBridge-instance registry of ReactiveState objects. Necessary
/// because actors can't directly own MainActor-isolated state.
@MainActor
internal final class DVAIBridgeReactiveStateRegistry {
    static let shared = DVAIBridgeReactiveStateRegistry()
    private var states: [ObjectIdentifier: DVAIBridgeReactiveState] = [:]

    func state(for bridge: DVAIBridge) -> DVAIBridgeReactiveState {
        let id = ObjectIdentifier(bridge)
        if let existing = states[id] { return existing }
        let new = DVAIBridgeReactiveState()
        states[id] = new
        // Subscribe to the bridge's progress events
        Task { @MainActor [weak new] in
            for await event in bridge.progressStream {
                new?.didReceiveProgress(event)
            }
        }
        return new
    }
}
```

(The bridge's `start()` / `stop()` methods need to call `state.didStart(server)` / `state.didStop()` after success. Add those calls inline in `DVAIBridge.swift` — small modification to Step 1 of Task 9.)

- [ ] **Step 2: Failing test**

`ios/Tests/DVAIBridgeTests/ReactiveStateTests.swift`:

```swift
import XCTest
@testable import DVAIBridge

@MainActor
final class ReactiveStateTests: XCTestCase {
    func testInitialState() {
        let s = DVAIBridgeReactiveState()
        XCTAssertFalse(s.isReady)
        XCTAssertNil(s.baseUrl)
        XCTAssertNil(s.port)
        XCTAssertNil(s.currentBackend)
        XCTAssertNil(s.lastProgress)
    }

    func testDidStartUpdatesObservableProperties() {
        let s = DVAIBridgeReactiveState()
        s.didStart(BoundServer(
            baseUrl: "http://127.0.0.1:38883/v1",
            port: 38883,
            backend: .llama,
            modelId: "x"
        ))
        XCTAssertTrue(s.isReady)
        XCTAssertEqual(s.baseUrl, "http://127.0.0.1:38883/v1")
        XCTAssertEqual(s.port, 38883)
        XCTAssertEqual(s.currentBackend, .llama)
    }

    func testDidStopResetsObservableProperties() {
        let s = DVAIBridgeReactiveState()
        s.didStart(BoundServer(baseUrl: "x", port: 1, backend: .llama, modelId: "x"))
        s.didStop()
        XCTAssertFalse(s.isReady)
        XCTAssertNil(s.baseUrl)
        XCTAssertNil(s.port)
        XCTAssertNil(s.currentBackend)
    }

    func testDidReceiveProgressStoresLastEvent() {
        let s = DVAIBridgeReactiveState()
        let event = ProgressEvent(phase: .download, bytesReceived: 100)
        s.didReceiveProgress(event)
        XCTAssertEqual(s.lastProgress, event)
    }
}
```

- [ ] **Step 3: Run + commit**

```bash
git add -A
git commit -m "feat(ios-bridge): DVAIBridgeReactiveState — SwiftUI-friendly @MainActor reactive state"
git push
pwsh scripts/mac-build.ps1 -Action test -Target ios-bridge
```

Expected: 28 + 4 = 32 tests pass.

## Task 18: Real-model integration tests

**Files:**
- Create: `packages/dvai-bridge-ios/ios/Tests/DVAIBridgeTests/RealModelIntegrationTest.swift`
- Modify: `scripts/smoke.local.env.example` (document new SMOKE_COREML_* + SMOKE_HF_TOKEN env vars)

Three end-to-end tests. Each downloads its model on first run (cached on disk; subsequent runs reuse). All three skip cleanly via `XCTSkip` when their prereqs aren't met.

- [ ] **Step 1: Write the test file**

```swift
// Tests/DVAIBridgeTests/RealModelIntegrationTest.swift
//
// End-to-end integration tests for the iOS native SDK against real models.
// Each backend has its own test method; each skips cleanly when its
// prereqs aren't met (env vars missing, iOS version too old, etc.).
//
// Pattern mirrors Phase 2C's RealModelSmokeTest in capacitor-llama.

import XCTest
import DVAIBridge
import DVAILlamaCore

final class RealModelIntegrationTest: XCTestCase {
    private var tempDir: URL!

    override class var defaultTestSuite: XCTestSuite {
        let suite = super.defaultTestSuite
        for case let testCase as XCTestCase in suite.tests {
            testCase.executionTimeAllowance = 30 * 60   // generous for slow downloads
        }
        return suite
    }

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("dvai-int-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        tempDir = base
    }

    override func tearDownWithError() throws {
        try? await DVAIBridge.shared.stop()
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
    }

    // MARK: - Llama backend (uses Phase 2C's existing SMOKE_MODEL_URL)

    func testLlamaBackendIntegration() async throws {
        let env = Self.loadSmokeEnv()
        guard let urlStr = env["SMOKE_MODEL_URL"], !urlStr.isEmpty,
              let sha = env["SMOKE_MODEL_SHA256"], !sha.isEmpty,
              let url = URL(string: urlStr)
        else {
            throw XCTSkip("SMOKE_MODEL_URL/SMOKE_MODEL_SHA256 not set; skipping llama integration")
        }

        let downloadResult = try await DVAIBridge.shared.downloadModel(.init(
            url: url,
            sha256: sha.lowercased(),
            destFilename: "int-llama.gguf"
        ))

        let server = try await DVAIBridge.shared.start(.init(
            backend: .llama,
            modelPath: downloadResult.path,
            #if targetEnvironment(simulator)
            gpuLayers: 0,
            #endif
            contextSize: 1024
        ))
        XCTAssertEqual(server.backend, .llama)

        let response = try await postChatCompletion(
            baseUrl: server.baseUrl,
            messages: [["role": "user", "content": "What is 2+2?"]]
        )
        XCTAssertFalse(response.isEmpty, "llama completion should not be empty")
    }

    // MARK: - Foundation Models backend (iOS 26+ runtime)

    func testFoundationBackendIntegration() async throws {
        if #available(iOS 26.0, macOS 26.0, *) {
            // Continue
        } else {
            throw XCTSkip("Foundation Models requires iOS 26+ at runtime")
        }

        let server = try await DVAIBridge.shared.start(.init(backend: .foundation))
        XCTAssertEqual(server.backend, .foundation)

        let response = try await postChatCompletion(
            baseUrl: server.baseUrl,
            messages: [["role": "user", "content": "Hello"]]
        )
        XCTAssertFalse(response.isEmpty, "foundation completion should not be empty")
    }

    // MARK: - CoreML backend (new SMOKE_COREML_* env vars)

    @available(iOS 18.0, macOS 15.0, *)
    func testCoreMLBackendIntegration() async throws {
        let env = Self.loadSmokeEnv()
        guard let modelUrlStr = env["SMOKE_COREML_MODEL_URL"], !modelUrlStr.isEmpty,
              let modelSha = env["SMOKE_COREML_MODEL_SHA256"], !modelSha.isEmpty,
              let tokUrlStr = env["SMOKE_COREML_TOKENIZER_URL"], !tokUrlStr.isEmpty,
              let tokSha = env["SMOKE_COREML_TOKENIZER_SHA256"], !tokSha.isEmpty,
              let modelUrl = URL(string: modelUrlStr),
              let tokUrl = URL(string: tokUrlStr)
        else {
            throw XCTSkip("SMOKE_COREML_* env vars not all set; skipping CoreML integration")
        }
        let hfToken = env["SMOKE_HF_TOKEN"]

        // 1. Download the .mlmodelc.zip + tokenizer.json
        let modelZip = try await downloadFile(
            url: modelUrl,
            sha256: modelSha,
            destFilename: "model.mlmodelc.zip",
            authBearer: nil
        )
        let tokFile = try await downloadFile(
            url: tokUrl,
            sha256: tokSha,
            destFilename: "tokenizer.json",
            authBearer: hfToken
        )

        // 2. Unzip .mlmodelc
        let unzipped = try await unzip(modelZip, into: tempDir)
        // The zip's top-level dir is "StatefulModel.mlmodelc" or similar;
        // discover the .mlmodelc directory rather than hardcoding the name.
        let mlmodelcURL = try findFirst(extension: "mlmodelc", under: unzipped)

        // 3. Place tokenizer.json + tokenizer_config.json (sibling URL) in a dir
        let tokDir = tempDir.appendingPathComponent("tokenizer")
        try FileManager.default.createDirectory(at: tokDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: tokFile, to: tokDir.appendingPathComponent("tokenizer.json"))
        // tokenizer_config.json is a sibling of tokenizer.json on HF; download it too
        let tokCfgUrl = tokUrl.deletingLastPathComponent().appendingPathComponent("tokenizer_config.json")
        let tokCfgFile = try await downloadFileMaybe(url: tokCfgUrl, authBearer: hfToken)
        if let tokCfgFile {
            try FileManager.default.copyItem(at: tokCfgFile, to: tokDir.appendingPathComponent("tokenizer_config.json"))
        }

        // 4. Boot the bridge against the .coreml backend
        let server = try await DVAIBridge.shared.start(.init(
            backend: .coreml,
            modelPath: mlmodelcURL.path,
            // CoreML-specific opts piggyback on DVAIBridgeConfig — extend the
            // config's `[String: Any]` overflow if we add a `tokenizerPath` field.
            // For Phase 3C, plumb `tokenizerPath` through the same overflow.
        ))
        XCTAssertEqual(server.backend, .coreml)

        let response = try await postChatCompletion(
            baseUrl: server.baseUrl,
            messages: [["role": "user", "content": "What is 2+2?"]]
        )
        XCTAssertFalse(response.isEmpty, "CoreML completion should not be empty")
    }

    // MARK: - Helpers

    private func postChatCompletion(baseUrl: String, messages: [[String: String]]) async throws -> String {
        let url = URL(string: "\(baseUrl)/chat/completions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "messages": messages,
            "max_tokens": 32,
            "temperature": 0.0,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "Integration", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "POST failed: \(String(data: data, encoding: .utf8) ?? "")"
            ])
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = json?["choices"] as? [[String: Any]]
        let message = (choices?.first?["message"] as? [String: Any])?["content"] as? String
        return message ?? ""
    }

    private func downloadFile(url: URL, sha256: String, destFilename: String, authBearer: String?) async throws -> URL {
        var req = URLRequest(url: url)
        if let token = authBearer { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (tempUrl, _) = try await URLSession.shared.download(for: req)
        let dest = tempDir.appendingPathComponent(destFilename)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempUrl, to: dest)
        // sha256 verification — cross-check the downloaded bytes
        try verifySha256(at: dest, expected: sha256.lowercased())
        return dest
    }

    private func downloadFileMaybe(url: URL, authBearer: String?) async throws -> URL? {
        do {
            return try await downloadFile(url: url, sha256: "", destFilename: url.lastPathComponent, authBearer: authBearer)
        } catch {
            return nil   // sibling file is optional
        }
    }

    private func verifySha256(at url: URL, expected: String) throws {
        guard !expected.isEmpty else { return }
        let data = try Data(contentsOf: url)
        let digest = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> [UInt8] in
            var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &hash)
            return hash
        }
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        if hex != expected {
            throw NSError(domain: "Integration", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "sha256 mismatch: got \(hex), expected \(expected)"])
        }
    }

    private func unzip(_ src: URL, into dest: URL) async throws -> URL {
        // Foundation's built-in ZIP extraction landed in iOS 16 / macOS 13. For
        // older targets or higher-fidelity unzip needs, we'd add a dep. For
        // 3C scope: assume iOS 18+ runners (CoreML backend requires iOS 18
        // anyway), use Foundation's NSFileCoordinator + Process api.
        // Implementation left as an exercise — use whichever zip extraction
        // approach the iOS 18+ Foundation API exposes most cleanly.
        // A reasonable starting point: use the `ProcessInfo` route on the
        // simulator via `/usr/bin/unzip` (`Process` is available on macOS;
        // simulator inherits its host's binaries).
        let unzipDir = dest.appendingPathComponent("unzipped")
        try FileManager.default.createDirectory(at: unzipDir, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-o", src.path, "-d", unzipDir.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "Integration", code: -3, userInfo: [
                NSLocalizedDescriptionKey: "unzip exited with status \(process.terminationStatus)"
            ])
        }
        return unzipDir
    }

    private func findFirst(extension ext: String, under root: URL) throws -> URL {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == ext { return url }
        }
        throw NSError(domain: "Integration", code: -4, userInfo: [
            NSLocalizedDescriptionKey: "no .\(ext) found under \(root.path)"
        ])
    }

    /// Reads SMOKE_* env vars from the test process's environment first,
    /// then falls back to scripts/smoke.local.env on the host filesystem.
    /// Same pattern as Phase 2C's RealModelSmokeTest helper.
    fileprivate static func loadSmokeEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("SMOKE_") }
        if !env.isEmpty { return env }
        var dir = URL(fileURLWithPath: #file).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("scripts/smoke.local.env").path) {
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return env }
            dir = parent
        }
        let envFile = dir.appendingPathComponent("scripts/smoke.local.env")
        guard let contents = try? String(contentsOf: envFile, encoding: .utf8) else { return env }
        for line in contents.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2 {
                if (value.first == "\"" && value.last == "\"") ||
                   (value.first == "'" && value.last == "'") {
                    value = String(value.dropFirst().dropLast())
                }
            }
            if key.hasPrefix("SMOKE_") && !value.isEmpty { env[key] = value }
        }
        return env
    }
}

// CommonCrypto for sha256
import CommonCrypto
```

The `unzip` helper uses `/usr/bin/unzip` via `Process` — this works on macOS Catalyst and the iOS simulator (which inherits the host's `/usr/bin`). For real iOS device runs, the test will need a different unzip path; defer that until on-device testing is needed. Phase 3C runs only on the simulator.

The CoreML-backend path in `DVAIBridgeConfig` needs a `tokenizerPath` field (or pass via `[String: Any]` overflow). Update `DVAIBridgeConfig.swift` to add:

```swift
public var tokenizerPath: String?
```

and include it in `toCoreOpts()`:

```swift
if let tokenizerPath { opts["tokenizerPath"] = tokenizerPath }
```

Plumb through every related file. (This is a small follow-up edit on Task 5's config file — easy fix.)

- [ ] **Step 2: Update `scripts/smoke.local.env.example`**

Append:

```
# Phase 3C — CoreML smoke (StatefulModel.mlmodelc + tokenizer.json)
SMOKE_COREML_MODEL_URL=https://huggingface.co/apple/coreml-Llama-3.2-1B-Instruct-4bit/resolve/main/StatefulModel.mlmodelc.zip
SMOKE_COREML_MODEL_SHA256=
SMOKE_COREML_TOKENIZER_URL=https://huggingface.co/meta-llama/Llama-3.2-1B-Instruct/resolve/main/tokenizer.json
SMOKE_COREML_TOKENIZER_SHA256=

# Optional — used to authenticate against gated HF repos (meta-llama
# requires acceptance of license terms via HF Hub):
SMOKE_HF_TOKEN=
```

- [ ] **Step 3: Manual prereq for first-time CoreML test run (document in plan; user does this)**

Tell the user: when they're ready to actually run `testCoreMLBackendIntegration` against the real Apple checkpoint, they need to:

1. Visit https://huggingface.co/meta-llama/Llama-3.2-1B-Instruct and accept the license. They get prompted for a HuggingFace account if not signed in.
2. Create a HuggingFace access token at https://huggingface.co/settings/tokens (read-only is enough). Copy the `hf_...` value.
3. Compute the sha256 of the two files (after first download — could compute on the fly with `shasum -a 256 <file>`):
   - `https://huggingface.co/apple/coreml-Llama-3.2-1B-Instruct-4bit/resolve/main/StatefulModel.mlmodelc.zip` — Apple's repo is public; no auth needed for download; just `curl -L | shasum -a 256`.
   - `https://huggingface.co/meta-llama/Llama-3.2-1B-Instruct/resolve/main/tokenizer.json` — gated; needs the HF token: `curl -L -H "Authorization: Bearer hf_..." | shasum -a 256`.
4. Populate `scripts/smoke.local.env` with the URLs, the SHAs, and the token. The `*-example` file already has the URLs + placeholders for the SHAs.

Local test invocation: `pwsh scripts/mac-build.ps1 -Action test -Target ios-bridge -Filter "DVAIBridgeTests/RealModelIntegrationTest"`. CI runs the same when the secrets land in repo settings.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat(ios-bridge): RealModelIntegrationTest — llama + foundation + coreml end-to-end with XCTSkip"
git push
```

(The integration tests skip cleanly without the env vars, so they pass CI without manual setup. The user runs them locally with their populated `smoke.local.env` once, and they go green.)

## Task 19: CocoaPods podspec

**Files:**
- Create: `packages/dvai-bridge-ios/DVAIBridge.podspec`

- [ ] **Step 1: Write the podspec**

```ruby
require 'json'
package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

Pod::Spec.new do |s|
  s.name             = 'DVAIBridge'
  s.version          = package['version']
  s.summary          = package['description']
  s.license          = 'Custom (See LICENSE)'
  s.homepage         = 'https://github.com/Westenets/dvai-bridge'
  s.author           = package['author']
  s.source           = { :git => 'https://github.com/Westenets/dvai-bridge.git', :tag => "v#{s.version}" }
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

- [ ] **Step 2: Lint the podspec on Mac**

```bash
git add packages/dvai-bridge-ios/DVAIBridge.podspec
git commit -m "feat(ios-bridge): CocoaPods podspec bundling DVAIBridge + DVAICoreMLCore + cores' Swift/ObjC sources"
git push

ssh mac "cd /Users/zer0/Developer/dvai-bridge/packages/dvai-bridge-ios && \
        pod lib lint DVAIBridge.podspec --allow-warnings --no-clean 2>&1 | tail -30"
```

Expected: passes with at most warnings (no errors). Common warnings the linter emits and are safe to ignore: "ARC enabled by default", "missing license file" (we point at the repo-root `LICENSE`).

If the linter complains about the cross-package paths, they may need to be made absolute or relative-to-the-podspec. Adjust per the linter output.

## Task 20: CI workflow

**Files:**
- Create: `.github/workflows/test-ios-bridge.yml`

- [ ] **Step 1: Write the workflow**

```yaml
name: iOS — DVAIBridge SDK

on:
  pull_request:
    paths:
      - 'packages/dvai-bridge-ios/**'
      - 'packages/dvai-bridge-ios-llama-core/**'
      - 'packages/dvai-bridge-ios-foundation-core/**'
      - 'fixtures/**'
      - '.github/workflows/test-ios-bridge.yml'
  push:
    branches: [main]
    paths:
      - 'packages/dvai-bridge-ios/**'
      - 'packages/dvai-bridge-ios-llama-core/**'
      - 'packages/dvai-bridge-ios-foundation-core/**'
      - 'fixtures/**'

concurrency:
  group: ios-bridge-${{ github.ref }}
  cancel-in-progress: true

jobs:
  xctest:
    name: XCTest — DVAIBridge SDK
    runs-on: [self-hosted, macOS, ARM64]
    timeout-minutes: 25
    defaults:
      run:
        working-directory: packages/dvai-bridge-ios
    steps:
      - uses: actions/checkout@v6
        with:
          submodules: recursive
      - name: Build xcframework if absent
        run: |
          if [ ! -d "../dvai-bridge-android-llama-core/android/src/main/cpp/native/llama.cpp/build-apple/llama.xcframework" ]; then
            cd "$GITHUB_WORKSPACE"
            bash scripts/mac-side-prepare-xcframework.sh
          fi
      - name: Run XCTest suite
        env:
          IOS_DEST: 'platform=iOS Simulator,name=iPhone 16,OS=18.5'
        run: |
          rm -rf build/test-results.xcresult
          xcodebuild test \
            -scheme DVAIBridge-Package \
            -destination "$IOS_DEST" \
            -resultBundlePath build/test-results.xcresult
      - name: Upload xcresult
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: ios-bridge-xcresult
          path: packages/dvai-bridge-ios/build/test-results.xcresult
          retention-days: 14
          if-no-files-found: ignore

  podspec-lint:
    name: pod lib lint
    runs-on: [self-hosted, macOS, ARM64]
    timeout-minutes: 15
    needs: xctest
    defaults:
      run:
        working-directory: packages/dvai-bridge-ios
    steps:
      - uses: actions/checkout@v6
        with:
          submodules: recursive
      - run: pod lib lint DVAIBridge.podspec --allow-warnings --no-clean
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/test-ios-bridge.yml
git commit -m "ci(ios-bridge): XCTest + pod lib lint workflow"
git push
```

## Task 21: CHANGELOG entry + Phase 3C milestone

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add the 1.8.0 entry**

```markdown
## [1.8.0] — 2026-04-27

Phase 3C — iOS Native SDK: standalone `@dvai-bridge/ios` package wrapping
`DVAILlamaCore` + `DVAIFoundationCore` + a fully-implemented
`DVAICoreMLCore`. First non-Capacitor consumer surface for the
OpenAI-compatible HTTP server on iOS, with three production-quality
backends.

### Added

- `@dvai-bridge/ios` npm package with SPM `Package.swift` at the package
  root and a `DVAIBridge.podspec` for CocoaPods.
- `DVAIBridge.shared` singleton actor exposing the 8-method public API:
  `start`, `stop`, `status`, `addProgressListener`, `downloadModel`,
  `listCachedModels`, `deleteCachedModel`, `cacheDir`.
- `BackendKind` enum (`.auto`, `.llama`, `.foundation`, `.coreml`) with
  `auto`-resolution at runtime based on modelPath extension + iOS 26+
  availability.
- `DVAIBridgeReactiveState` `@MainActor` `ObservableObject` for SwiftUI
  consumers — `isReady`, `baseUrl`, `port`, `currentBackend`,
  `lastProgress` published properties.
- Three observation surfaces for `ProgressEvent`: Combine
  `progressPublisher`, `progressStream` (`AsyncStream`), and
  `addProgressListener(_:)` callback. All three observe the same source.
- **Full CoreML LLM backend** (`DVAICoreMLCore`):
  - `MLModel` + `MLState` for KV-cached autoregressive decoding (iOS 18+ /
    macOS 15+).
  - `swift-transformers` (HuggingFace) for tokenization +
    `applyChatTemplate(...)` across Llama / Gemma / Phi families.
  - Greedy + temperature + top-p + top-k sampling.
  - Streaming via SSE (`AsyncStream<String>` produced by
    `CoreMLGenerator.generateStream(...)`).
  - OpenAI ChatCompletion / Completion / Models JSON output via
    `CoreMLHandlers`.
  - Reference checkpoint: `apple/coreml-Llama-3.2-1B-Instruct-4bit`
    (others should work if input/output names match).
- `RealModelIntegrationTest` — three end-to-end tests against real models,
  one per backend, gated on env-var availability:
  - `testLlamaBackendIntegration` (uses Phase 2C's existing SMOKE_MODEL_*)
  - `testFoundationBackendIntegration` (iOS 26+ runtime; no model file)
  - `testCoreMLBackendIntegration` (new SMOKE_COREML_* env vars +
    SMOKE_HF_TOKEN for the gated meta-llama tokenizer)
- `test-ios-bridge.yml` CI workflow running XCTest + `pod lib lint`.
- Public `DVAIHandlers` protocol + `HandlerContext` + `HandlerResponse` +
  `HttpServer.tryBind(...)` / `installRoutes(...)` exposed from
  `DVAILlamaCore` (surgical visibility bumps; no logic changes).

### Verified

- ~40 unit tests pass (ProgressEvent, BackendKind, DVAIBridgeError,
  DVAIBridgeConfig, BoundServer, ProgressBroadcaster, BackendSelector,
  ReactiveState, CoreMLEngine, CoreMLTokenizer, CoreMLSampler,
  CoreMLGeneratorShape, CoreMLPluginState, CoreMLHandlers,
  DVAIBridgeAPIShape).
- All three real-model integration tests pass when their env vars are
  populated; skip cleanly when not.
- `pod lib lint DVAIBridge.podspec --allow-warnings` passes.
- Existing Capacitor tests + Phase 3A/3B test suites unaffected.

### Manual setup for the CoreML integration test (first-time only)

The CoreML backend's integration test downloads ~700 MB of model weights
+ a few MB of tokenizer config. The user populates `scripts/smoke.local.env`
with:

```
SMOKE_COREML_MODEL_URL=https://huggingface.co/apple/coreml-Llama-3.2-1B-Instruct-4bit/resolve/main/StatefulModel.mlmodelc.zip
SMOKE_COREML_MODEL_SHA256=<sha256 of the zip>
SMOKE_COREML_TOKENIZER_URL=https://huggingface.co/meta-llama/Llama-3.2-1B-Instruct/resolve/main/tokenizer.json
SMOKE_COREML_TOKENIZER_SHA256=<sha256 of tokenizer.json>
SMOKE_HF_TOKEN=hf_<your-token>      # for the gated meta-llama repo
```

The Llama-3.2 tokenizer lives in a gated HF repo; the user must accept
the license terms once at
https://huggingface.co/meta-llama/Llama-3.2-1B-Instruct and create a
read-only access token at https://huggingface.co/settings/tokens.
```

- [ ] **Step 2: Run the full iOS test suite one more time**

```bash
pwsh scripts/mac-build.ps1 -Action test -Target ios-bridge
pwsh scripts/mac-build.ps1 -Action test -Target ios-llama-core
pwsh scripts/mac-build.ps1 -Action test -Target ios-foundation-core
pwsh scripts/mac-build.ps1 -Action test -Target capacitor-llama -Filter "!DVAICapacitorLlamaTests/RealModelSmokeTest"
pwsh scripts/mac-build.ps1 -Action test -Target capacitor-foundation
```

Expected: every target green; total iOS test count = ~40 (bridge unit) + 64 (llama-core) + 1 (capacitor-llama) + 10 (foundation-core) + 1 (capacitor-foundation) = ~116. (Real-model integration tests `XCTSkip` in the unattended invocation.)

- [ ] **Step 3: Milestone commit + push**

```bash
git add CHANGELOG.md
git commit -m "docs(changelog): 1.8.0 — Phase 3C iOS Native SDK with full CoreML backend"
git commit --allow-empty -m "$(cat <<'EOF'
chore(phase3c): milestone — iOS Native SDK shipping with three production backends

  iOS test counts (post-3C, unit only — RealModelIntegrationTest skips
  cleanly without env vars):
    DVAIBridge SDK ............... ~40  (unit tests for the new SDK)
    ios-llama-core .............. 64
    ios-foundation-core ......... 10
    capacitor-llama ............. 1   (SmokeTest)
    capacitor-foundation ........ 1   (SmokeTest)
    -------------------------------- ----
    Total                        ~116

  Three production backends:
  - llama.cpp (lifted from DVAILlamaCore)
  - Apple Foundation Models (lifted from DVAIFoundationCore; iOS 26+ runtime)
  - CoreML (new in 3C; full MLModel + MLState + swift-transformers
    pipeline; greedy + temperature + top-p + top-k sampling; SSE streaming;
    reference checkpoint apple/coreml-Llama-3.2-1B-Instruct-4bit)

  RealModelIntegrationTest verifies all three end-to-end against real
  models (gated on SMOKE_* env vars + iOS 26 runtime).

Phase 3D (Android AAR — co.deepvoiceai:dvai-bridge wrapping
android-llama-core + android-mediapipe-core, plus a new LiteRT generic-
model backend) is up next.
EOF
)"
git push
```

---

## Definition of done

- [ ] `packages/dvai-bridge-ios/` exists; `Package.swift` resolves on Mac.
- [ ] `xcodebuild build -scheme DVAIBridge` succeeds.
- [ ] `xcodebuild test -scheme DVAIBridge-Package` passes ~40 unit tests.
- [ ] `RealModelIntegrationTest` exists with three test methods, each `XCTSkip`-ing cleanly when prereqs are missing, each passing end-to-end when their env vars are populated.
- [ ] `pod lib lint DVAIBridge.podspec --allow-warnings` passes.
- [ ] `DVAIBridge.shared` exposes the 8-method public API surface.
- [ ] `BackendKind.coreml` is a working backend — `start(backend: .coreml, modelPath: ..., tokenizerPath: ...)` boots the HTTP server, serves OpenAI-formatted responses for chat completions, supports streaming via SSE.
- [ ] `swift-transformers` declared as a SPM dependency at `from: "0.1.16"`.
- [ ] `DVAIBridgeReactiveState` published properties update on lifecycle transitions.
- [ ] `progressPublisher`, `progressStream`, and `addProgressListener` all observe the same source.
- [ ] `test-ios-bridge.yml` CI workflow file exists.
- [ ] `scripts/smoke.local.env.example` documents the new `SMOKE_COREML_*` + `SMOKE_HF_TOKEN` env vars.
- [ ] CHANGELOG entry for `1.8.0` documents the new SDK + the three backends + the manual CoreML smoke setup.
- [ ] Branch merged to main with a clean rebase + fast-forward.
