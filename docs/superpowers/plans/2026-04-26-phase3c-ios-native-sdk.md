# Phase 3C — iOS Native SDK Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to execute this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up `packages/dvai-bridge-ios/` — a top-level iOS SDK that wraps `DVAILlamaCore` + `DVAIFoundationCore` (existing) + a new stub `DVAICoreMLCore`, exposes a unified `DVAIBridge.shared` API, and ships via SPM + CocoaPods.

**Architecture:** Single SPM package with three Swift targets (`DVAIBridge`, `DVAICoreMLCore`, `DVAIBridgeTests`). Two path-dep references to the existing core packages — no source duplication. CoreML backend ships as a stub (`throws notYetImplemented`) so `BackendKind.coreml` is a valid enum case today; full implementation is a follow-up sub-phase. Public API mirrors the Capacitor JS shim's 8-method surface, plus iOS-native conveniences (Combine publisher, AsyncStream, `@Observable` / `ObservableObject` reactive state).

**Tech Stack:** Swift 5.9+ / SPM (path-dep references) / CocoaPods (bundled-source pattern from Phase 3A) / Telegraph (HTTP server, transitively from cores) / Combine + AsyncStream (progress events) / `@Observable` macro (iOS 17+) + `ObservableObject` (iOS < 17 fallback).

**Spec:** [`docs/superpowers/specs/2026-04-26-phase3c-ios-native-sdk-design.md`](../specs/2026-04-26-phase3c-ios-native-sdk-design.md)

**Branch:** `feat/phase3c-ios-native-sdk` off `main`. Implementation done in worktree `.worktrees/phase3c-ios-native-sdk`.

**Phase boundaries:**

- **Tasks 1-3:** Package scaffold (npm metadata, Package.swift, README, .gitkeep placeholders).
- **Tasks 4-7:** Public API types — config, BoundServer, ProgressEvent, errors, backend kind enum.
- **Tasks 8-10:** Backend selector + DVAIBridge actor implementing the 8-method surface.
- **Tasks 11-12:** Progress event broadcaster (Combine + AsyncStream + callback).
- **Task 13:** Reactive state (`@Observable` + `ObservableObject`).
- **Task 14:** CoreML stub.
- **Tasks 15-17:** Tests (unit + integration).
- **Task 18:** CocoaPods podspec.
- **Task 19:** CI workflow.
- **Task 20:** Phase 3C milestone + CHANGELOG.

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

## Task 8: CoreML stub backend

**Files:**
- Create: `packages/dvai-bridge-ios/ios/Sources/DVAICoreMLCore/CoreMLBackendError.swift`
- Create: `packages/dvai-bridge-ios/ios/Sources/DVAICoreMLCore/CoreMLPluginState.swift`

- [ ] **Step 1: Write `CoreMLBackendError.swift`**

```swift
import Foundation

public enum CoreMLBackendError: Error, LocalizedError, Sendable {
    case notYetImplemented(String)

    public var errorDescription: String? {
        switch self {
        case .notYetImplemented(let msg): return msg
        }
    }
}
```

- [ ] **Step 2: Write `CoreMLPluginState.swift`**

```swift
import Foundation

/// Stub PluginState that mirrors the shape of `DVAILlamaCore.PluginState`
/// and `DVAIFoundationCore.PluginState` so DVAIBridge can dispatch to it
/// uniformly. Phase 3C ships only the package shape; full LLM-style
/// generation lands in a follow-up sub-phase.
public actor CoreMLPluginState {
    public init() {}

    public func start(opts: [String: Any]) async throws -> [String: Any] {
        throw CoreMLBackendError.notYetImplemented(
            "CoreML LLM generation is not yet implemented in this version of " +
            "@dvai-bridge/ios. Use BackendKind.llama or BackendKind.foundation. " +
            "Track the CoreML implementation in the project's Phase 3C+ plan."
        )
    }

    public func stop() async throws {
        // No-op; nothing was started.
    }

    public func statusInfo() -> [String: Any] {
        ["running": false]
    }
}
```

- [ ] **Step 3: Replace the placeholder**

```bash
git rm packages/dvai-bridge-ios/ios/Sources/DVAICoreMLCore/_Placeholder.swift 2>/dev/null || \
git rm packages/dvai-bridge-ios/ios/Sources/DVAICoreMLCore/.gitkeep 2>/dev/null || true
```

- [ ] **Step 4: Failing test**

`ios/Tests/DVAIBridgeTests/CoreMLStubTests.swift`:

```swift
import XCTest
@testable import DVAIBridge
import DVAICoreMLCore

final class CoreMLStubTests: XCTestCase {
    func testStartThrowsNotYetImplemented() async {
        let state = CoreMLPluginState()
        do {
            _ = try await state.start(opts: [:])
            XCTFail("Expected throw, got success")
        } catch let err as CoreMLBackendError {
            switch err {
            case .notYetImplemented(let msg):
                XCTAssertTrue(msg.contains("not yet implemented"))
                XCTAssertTrue(msg.contains("BackendKind"))
            }
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    func testStopIsNoOp() async throws {
        try await CoreMLPluginState().stop()
        // doesn't throw
    }

    func testStatusInfoReportsNotRunning() async {
        let state = CoreMLPluginState()
        let info = state.statusInfo()
        XCTAssertEqual(info["running"] as? Bool, false)
    }
}
```

- [ ] **Step 5: Run + commit**

```bash
git add -A
git commit -m "feat(coreml-core): stub PluginState that throws notYetImplemented + tests"
git push
pwsh scripts/mac-build.ps1 -Action test -Target ios-bridge
```

Expected: 21 + 3 = 24 tests pass.

## Task 9: DVAIBridge actor (the main API)

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

## Task 10: Reactive state (`@Observable` + `ObservableObject`)

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

## Task 11: CocoaPods podspec

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

## Task 12: CI workflow

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

## Task 13: CHANGELOG entry + Phase 3C milestone

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add the 1.8.0 entry**

```markdown
## [1.8.0] — 2026-04-26

Phase 3C — iOS Native SDK: standalone `@dvai-bridge/ios` package wrapping
`DVAILlamaCore` + `DVAIFoundationCore` + new stub `DVAICoreMLCore`. First
non-Capacitor consumer surface for the OpenAI-compatible HTTP server on
iOS.

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
- `DVAICoreMLCore` stub package (`CoreMLPluginState` throws
  `notYetImplemented` on `start()`); `BackendKind.coreml` is a valid case
  today, full implementation lands in a follow-up sub-phase.
- `test-ios-bridge.yml` CI workflow running XCTest + `pod lib lint`.

### Verified

- 32 XCTest unit tests pass (ProgressEvent, BackendKind, DVAIBridgeError,
  DVAIBridgeConfig, BoundServer, ProgressBroadcaster, BackendSelector,
  CoreMLStub, DVAIBridgeAPIShape, ReactiveState).
- `pod lib lint DVAIBridge.podspec --allow-warnings` passes.
- Existing Capacitor tests + Phase 3A/3B test suites unaffected.
```

- [ ] **Step 2: Run the full iOS test suite one more time**

```bash
pwsh scripts/mac-build.ps1 -Action test -Target ios-bridge
pwsh scripts/mac-build.ps1 -Action test -Target ios-llama-core
pwsh scripts/mac-build.ps1 -Action test -Target ios-foundation-core
pwsh scripts/mac-build.ps1 -Action test -Target capacitor-llama -Filter "!DVAICapacitorLlamaTests/RealModelSmokeTest"
pwsh scripts/mac-build.ps1 -Action test -Target capacitor-foundation
```

Expected: every target green; total iOS test count = 32 (bridge) + 64 (llama-core) + 1 (capacitor-llama) + 10 (foundation-core) + 1 (capacitor-foundation) = 108.

- [ ] **Step 3: Milestone commit + push**

```bash
git add CHANGELOG.md
git commit -m "docs(changelog): 1.8.0 — Phase 3C iOS Native SDK"
git commit --allow-empty -m "$(cat <<'EOF'
chore(phase3c): milestone — iOS Native SDK shipping

  iOS test counts (post-3C):
    DVAIBridge SDK ............... 32  (unit tests for the new SDK)
    ios-llama-core .............. 64
    ios-foundation-core ......... 10
    capacitor-llama ............. 1   (SmokeTest)
    capacitor-foundation ........ 1   (SmokeTest)
    -------------------------------- ----
    Total                        108

  CoreML backend ships as a stub (start() throws notYetImplemented). Full
  implementation deferred to a follow-up spec. BackendKind.coreml is a
  valid enum case today; consumers can write forward-looking code that
  compiles + the BackendSelector routes .mlmodelc / .mlpackage paths to
  it correctly.

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
- [ ] `xcodebuild test -scheme DVAIBridge-Package` passes 32 unit tests.
- [ ] `pod lib lint DVAIBridge.podspec --allow-warnings` passes.
- [ ] `DVAIBridge.shared` exposes the 8-method public API surface.
- [ ] `BackendKind.coreml` is a valid case; the stub throws `notYetImplemented` cleanly.
- [ ] `DVAIBridgeReactiveState` published properties update on lifecycle transitions.
- [ ] `progressPublisher`, `progressStream`, and `addProgressListener` all observe the same source.
- [ ] `test-ios-bridge.yml` CI workflow file exists.
- [ ] CHANGELOG entry for `1.8.0` documents the new SDK.
- [ ] Branch merged to main with a clean rebase + fast-forward.
