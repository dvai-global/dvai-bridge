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
4. Three concrete backends, all production-quality:
   - **llama.cpp** via `DVAILlamaCore` — already shipping on Capacitor; lift-and-reuse.
   - **Apple Foundation Models** via `DVAIFoundationCore` — already shipping on Capacitor; lift-and-reuse.
   - **CoreML** — new in 3C. Full text-generation pipeline: `MLModel` + `MLState` for KV-cached autoregressive decoding, `swift-transformers` for tokenization, greedy + temperature/top-p sampling, AsyncStream-based streaming, and OpenAI ChatCompletion / Completion / Models JSON output via a new `CoreMLHandlers`. See §4 for details.
5. Ship pure-Swift integration tests that prove a non-Capacitor consumer can `import DVAIBridge`, call `start()` against each backend, hit `http://127.0.0.1:38883/v1/chat/completions`, and get a response — same behavior as the Capacitor path. Three end-to-end tests, one per backend, each gated on availability (iOS 26+ for foundation; env-var-supplied model URLs for llama + coreml).
6. Reuse the existing xcframework binary distribution (llama.framework + mtmd.framework already produced by `scripts/mac-side-prepare-xcframework.sh`); 3C just hooks new SPM/podspec entries onto them.

## 2. Non-goals (3C)

- **CoreML vision / audio / embeddings.** First CoreML implementation handles text chat completions only. Vision-capable CoreML LLMs need their own input pre-processing layer (image tensors); audio likewise. Defer to a follow-up sub-phase once we have a customer demand signal.
- **CoreML model auto-download.** The SDK consumer supplies a path to a compiled `.mlmodelc` bundle on disk (and a tokenizer file). The user is responsible for sourcing the model. Phase 3C ships with documentation pointing at Apple's official CoreML conversions (e.g. `apple/coreml-Llama-3.2-1B-Instruct-4bit`).
- **CoreML model-format conversion tooling.** Apple's `coremltools` Python package handles `.gguf` / `.safetensors` → `.mlmodelc` conversion offline. The SDK consumes pre-converted models only.
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

## 4. CoreML backend — full implementation

### 4.1 Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  DVAIBridge.shared.start(.init(backend: .coreml,                │
│                                modelPath: "/path/to/model.mlmodelc", │
│                                ...))                            │
└─────────────────┬───────────────────────────────────────────────┘
                  ▼
┌─────────────────────────────────────────────────────────────────┐
│  CoreMLPluginState (actor)                                      │
│  ├─ Loads MLModel via MLModel(contentsOf: url, configuration:)  │
│  ├─ Initializes MLState for KV-cache (per-conversation)         │
│  ├─ Loads tokenizer via swift-transformers                      │
│  ├─ Boots Telegraph HTTP server (mirrors llama-core's HttpServer)│
│  └─ Installs CoreMLHandlers as the handler set                  │
└─────────────────┬───────────────────────────────────────────────┘
                  ▼
┌─────────────────────────────────────────────────────────────────┐
│  CoreMLHandlers (DVAIHandlers conformer)                        │
│  ├─ handleChatCompletion(body, ctx)                             │
│  │     → tokenize(messages) → generate(tokens) → format JSON    │
│  ├─ handleCompletion(body, ctx)  — legacy /v1/completions       │
│  ├─ handleModels(ctx) — single-entry list                       │
│  └─ handleEmbeddings — 501 (CoreML embedding deferred)          │
└─────────────────┬───────────────────────────────────────────────┘
                  ▼
┌─────────────────────────────────────────────────────────────────┐
│  CoreMLGenerator (orchestrates per-request generation)           │
│  ├─ Tokenizer.apply_chat_template(messages) → token IDs         │
│  ├─ MLModel prediction loop:                                    │
│  │   for step in maxTokens:                                     │
│  │     output = model.prediction(input: tokens, state: kvCache) │
│  │     nextToken = sample(logits: output.logits)                │
│  │     if nextToken == EOS: break                               │
│  │     tokens.append(nextToken)                                 │
│  │     yield tokenizer.decode(nextToken)  // for streaming      │
│  └─ Returns: text (sync) OR AsyncStream<String> (streaming)     │
└─────────────────────────────────────────────────────────────────┘
```

### 4.2 Dependencies

`DVAICoreMLCore` declares two new SPM dependencies (in addition to Telegraph for HTTP):

```swift
.package(url: "https://github.com/huggingface/swift-transformers.git", from: "0.1.16"),
.package(url: "https://github.com/Building42/Telegraph.git", from: "0.40.0"),  // already in cores
```

`swift-transformers` (Apache 2.0, HuggingFace-maintained, Apple-engineering-blessed) provides:
- `Tokenizers.AutoTokenizer.from(modelFolder:)` — load BPE / SentencePiece / WordPiece tokenizers from a `tokenizer.json` file
- `Tokenizer.apply_chat_template(messages:)` — apply the model's chat template (Llama, Gemma, Phi, etc. all supported)
- `Tokenizer.encode(text:)` / `.decode(tokens:)` — round-trip
- `LLM.LanguageModel` — optional higher-level wrapper if we want it (we don't; we use `MLModel` directly for finer control over `MLState`)

### 4.3 Reference checkpoint

Phase 3C ships tested against **`apple/coreml-Llama-3.2-1B-Instruct-4bit`** (Apple's official CoreML conversion, ~700 MB on disk):

| Source | Path |
|---|---|
| HuggingFace model card | https://huggingface.co/apple/coreml-Llama-3.2-1B-Instruct-4bit |
| Direct download (StatefulModel.mlmodelc.zip) | https://huggingface.co/apple/coreml-Llama-3.2-1B-Instruct-4bit/resolve/main/StatefulModel.mlmodelc.zip |
| Tokenizer (HF Hub URL) | https://huggingface.co/meta-llama/Llama-3.2-1B-Instruct/resolve/main/tokenizer.json |

The implementation works against any CoreML LLM that follows the same input/output convention (single `inputIds: MLMultiArray<Int32>`, single `state: MLState` for KV-cache, single `logits: MLMultiArray<Float32>` output). Other models (Phi-3, Gemma 2 CoreML conversions) work without code changes if their input/output names match; if not, `CoreMLPluginState.start()` accepts an `opts["coremlInputName"]` / `opts["coremlOutputName"]` override.

### 4.4 Tokenizer integration

```swift
import Tokenizers

// At start():
let tokenizer = try await AutoTokenizer.from(modelFolder: tokenizerDir)
//  modelFolder must contain tokenizer.json + tokenizer_config.json (typical HF tokenizer dump)

// At handleChatCompletion():
let tokens = try tokenizer.applyChatTemplate(messages: messages, addGenerationPrompt: true)
// tokens: [Int] — the token IDs of the rendered chat template
```

`applyChatTemplate` handles model-specific chat formatting (Llama 3's `<|begin_of_text|><|start_header_id|>...`, Gemma's `<start_of_turn>...`, etc.) so handlers don't hardcode templates per model.

### 4.5 `MLModel` + `MLState` KV-cache

```swift
import CoreML

// Engine init:
let cfg = MLModelConfiguration()
cfg.computeUnits = .all  // CPU + GPU + ANE
let model = try MLModel(contentsOf: modelURL, configuration: cfg)

// Per-request KV-cache: stateful CoreML models expose a state via getState()
let kvCache = model.makeState()

// Decode loop:
for step in 0 ..< maxNewTokens {
    let inputArr = try MLMultiArray(shape: [1, 1], dataType: .int32)
    inputArr[0] = NSNumber(value: tokenIds.last!)

    let input = MLDictionaryFeatureProvider(dictionary: ["inputIds": inputArr])
    let output = try await model.prediction(from: input, options: opts, state: kvCache)
    let logits = output.featureValue(for: "logits")?.multiArrayValue
    let nextToken = sample(from: logits, temperature: temperature, topP: topP)
    if nextToken == eosTokenId { break }
    tokenIds.append(nextToken)
    onToken?(tokenizer.decode(token: nextToken))  // streaming
}
```

`MLState` (introduced in iOS 18 / macOS 15) is the canonical Apple API for stateful CoreML inference. Pre-iOS-18 fallback isn't planned for 3C — Apple's CoreML LLM checkpoints all target the new state API.

### 4.6 Sampling

```swift
internal struct Sampler {
    let temperature: Float
    let topP: Float

    func sample(logits: MLMultiArray) -> Int {
        if temperature <= 0 { return argmax(logits) }  // greedy
        let probs = softmax(logits, temperature: temperature)
        if topP < 1.0 { return nucleusSample(probs, topP: topP) }
        return categoricalSample(probs)
    }
}
```

Default: greedy (temperature = 0). User-overridable via the OpenAI request's `temperature` + `top_p` fields.

### 4.7 Streaming via SSE

`CoreMLHandlers.handleChatCompletion` returns either:
- A buffered JSON `ChatCompletion` object (when `stream: false`)
- An SSE event stream (when `stream: true`) — same SSE format the existing llama backend produces; `data: {"choices":[{"delta":{"content":"..."}}]}\n\n` per chunk + `data: [DONE]\n\n` at the end

The Telegraph HTTP server already handles SSE response shape; `CoreMLHandlers` produces an `AsyncStream<String>` of pre-formatted SSE chunks.

### 4.8 OpenAI handler conformance

`CoreMLHandlers` conforms to the same `DVAIHandlers` protocol the other cores already implement. The protocol contract (defined in `DVAILlamaCore.HandlerDispatch.swift`):

```swift
public protocol DVAIHandlers: Sendable {
    func handleChatCompletion(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse
    func handleCompletion(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse
    func handleEmbeddings(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse
    func handleModels(ctx: HandlerContext) async throws -> HandlerResponse
}
```

Phase 3C exposes this protocol publicly from `DVAILlamaCore` (or hoists it into a tiny `DVAIBridgeProtocols` module if cleaner) so `DVAICoreMLCore` can conform without depending on the entire llama core.

`CoreMLHandlers.handleEmbeddings` returns 501 with `{"error": "embeddings not yet supported by the CoreML backend"}`. Embeddings on CoreML LLMs require a separate model output (hidden states) that most checkpoints don't expose — defer until needed.

### 4.9 What's deferred to a follow-up

- Vision modality (image_url content parts) for vision-capable CoreML models. Apple ships a few; integration needs an image-tensor preprocessing path (`CIImage` → `MLMultiArray`).
- Audio modality (input_audio content parts).
- Embeddings endpoint (`/v1/embeddings`) for embedding-mode CoreML models.
- Auto-download / caching of CoreML models. Today the SDK consumes pre-loaded `.mlmodelc` paths; download via `DVAIBridge.shared.downloadModel(...)` works for arbitrary URLs but the developer is responsible for the unzip-and-compile step that turns `.mlmodelc.zip` → `.mlmodelc/`.
- LoRA adapters / fine-tuning. CoreML supports it; out of scope for the initial release.

### 4.10 Error type

```swift
public enum CoreMLBackendError: Error, LocalizedError, Sendable {
    case modelLoadFailed(reason: String)
    case tokenizerLoadFailed(reason: String)
    case stateInitFailed(reason: String)
    case generationFailed(reason: String)
    case unsupportedModelFormat(reason: String)
}
```

Maps cleanly to `DVAIBridgeError.backendError(...)` in the SDK layer.

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
- `BackendSelectorTests.swift` — exercises every branch of the `auto` heuristic. Verifies the throwing case ("auto backend requires a hint").
- `ProgressEventTests.swift` — Combine subscriber receives events, AsyncStream `for await` consumes events, callback `addProgressListener` is invoked with a `CancellationToken` that suppresses further events. All three observers see the same broadcast.
- `ReactiveStateTests.swift` — `start()` flips `isReady`, populates `baseUrl`, `currentBackend`. `stop()` resets.
- `CoreMLPluginStateTests.swift` — fake-injected `MLModel` + `Tokenizer` to exercise the plugin lifecycle without loading a real model. Asserts: `start()` rejects bad paths, `stop()` is idempotent, `statusInfo()` reports expected shape.
- `CoreMLSamplerTests.swift` — greedy returns argmax; temperature=1 returns sampled distribution; top-p truncates the tail correctly.
- `CoreMLHandlersTests.swift` — fake-injected generator; asserts handleChatCompletion produces correct OpenAI JSON shape, streaming yields SSE-formatted chunks, handleModels returns the configured model id.

### 6.2 Real-model integration tests (`RealModelIntegrationTest.swift`)

Three end-to-end tests, each gated on the per-backend availability requirement. Pattern follows Phase 2C's `RealModelSmokeTest` — env vars from `scripts/smoke.local.env` (read via the same `loadSmokeEnv()` helper), `XCTSkip` cleanly when prerequisites missing.

#### 6.2.1 `testLlamaBackendIntegration`

```
Reads:  SMOKE_MODEL_URL, SMOKE_MODEL_SHA256
Skips:  if either env var is empty
Flow:   download → DVAIBridge.shared.start(backend: .llama, modelPath: ...)
        → URLSession.shared.data(for: URL("\(baseUrl)/chat/completions"))
        → assert non-empty completion text
        → DVAIBridge.shared.stop()
```

Uses the same Llama-3.2-1B-Instruct GGUF the existing Phase 2C smoke uses; no new model needed.

#### 6.2.2 `testFoundationBackendIntegration`

```
Reads:  nothing — no model file required
Skips:  if iOS < 26.0 (or macOS < 26.0) at runtime
Flow:   DVAIBridge.shared.start(backend: .foundation)
        → POST /chat/completions with simple prompt
        → assert non-empty completion text
        → stop()
```

Apple manages the model. No download needed.

#### 6.2.3 `testCoreMLBackendIntegration`

```
Reads:  SMOKE_COREML_MODEL_URL          (e.g. .../StatefulModel.mlmodelc.zip)
        SMOKE_COREML_MODEL_SHA256
        SMOKE_COREML_TOKENIZER_URL      (HF tokenizer.json)
        SMOKE_COREML_TOKENIZER_SHA256
Skips:  if any env var is empty
Flow:   download model zip → unzip to .mlmodelc/ →
        download tokenizer.json + tokenizer_config.json (a sibling URL pattern) →
        DVAIBridge.shared.start(backend: .coreml,
                                modelPath: "<unzipped>.mlmodelc",
                                tokenizerPath: "<dir with tokenizer.json>")
        → POST /chat/completions
        → assert non-empty completion
        → stop()
```

#### 6.2.4 Manual setup (one-time)

Tell the developer running the tests:

1. Already-set env vars from Phase 2C (no change): `SMOKE_MODEL_URL`, `SMOKE_MODEL_SHA256` populate `scripts/smoke.local.env` for the llama integration test.

2. **New env vars to add to `scripts/smoke.local.env` for the CoreML integration test**:

```
# Phase 3C — CoreML smoke (StatefulModel.mlmodelc + tokenizer.json)
SMOKE_COREML_MODEL_URL=https://huggingface.co/apple/coreml-Llama-3.2-1B-Instruct-4bit/resolve/main/StatefulModel.mlmodelc.zip
SMOKE_COREML_MODEL_SHA256=<sha256 of the .zip — compute with `shasum -a 256 <file>` after first download>
SMOKE_COREML_TOKENIZER_URL=https://huggingface.co/meta-llama/Llama-3.2-1B-Instruct/resolve/main/tokenizer.json
SMOKE_COREML_TOKENIZER_SHA256=<sha256 of tokenizer.json>
```

3. The `meta-llama/Llama-3.2-1B-Instruct` repo is gated on HuggingFace. The test passes a `Authorization: Bearer <HF_TOKEN>` header if `SMOKE_HF_TOKEN` is set in the env. Add to `smoke.local.env`:

```
SMOKE_HF_TOKEN=hf_<your_token>
```

(Optional — Apple's CoreML repo is public; only the tokenizer at meta-llama needs auth.)

4. The Foundation Models integration test needs nothing — Apple's model is on-device and free. iOS 26+ runtime gates the test via `if #available`.

5. First run: the test downloads ~700 MB (CoreML model) + a few MB (tokenizer). Cached on disk; subsequent runs reuse the cache (`<App Support>/dvai-models/`).

#### 6.2.5 What runs automatically vs. what you trigger

- **Automatic on every PR / push:** `xctest` invocation — runs all unit tests + the foundation integration test (no setup needed). The llama and coreml integration tests `XCTSkip` because the env vars aren't present in CI.
- **Manual / nightly:** the smoke test workflow (`smoke-real-models.yml`, already exists from Phase 2C) extends to also invoke the bridge SDK's RealModelIntegrationTest. The same SMOKE secrets plus the new SMOKE_COREML_* secrets need to be populated in repo settings before the nightly cron picks them up.

### 6.3 CI

`.github/workflows/test-ios-bridge.yml` — runs `xcodebuild test -scheme DVAIBridge-Package -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5'`, plus a `pod lib lint` job. Triggers on changes to `packages/dvai-bridge-ios/**` or to either core. Uploads xcresult on failure.

`.github/workflows/smoke-real-models.yml` — extended to add a new step that invokes `RealModelIntegrationTest` against the real CoreML and llama models when the appropriate secrets are populated.

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
- [ ] `xcodebuild test -scheme DVAIBridge-Package` passes, with at least:
  - **Unit tests** (no real model load): API shape, backend selector, progress, reactive state, CoreMLPluginState lifecycle, CoreMLSampler greedy/temperature/top-p, CoreMLHandlers JSON output. Target ~40 unit tests.
  - **Real-model integration tests** (3 tests, each with `XCTSkip` if prereqs missing):
    - `testLlamaBackendIntegration` — uses the existing Phase 2C `SMOKE_MODEL_URL` env var
    - `testFoundationBackendIntegration` — runs unconditionally on iOS 26+, skips otherwise
    - `testCoreMLBackendIntegration` — uses new `SMOKE_COREML_*` env vars
- [ ] `pod lib lint DVAIBridge.podspec --allow-warnings` passes.
- [ ] `DVAIBridge.shared` exposes the 8-method surface that mirrors the Capacitor JS shim.
- [ ] `BackendKind.coreml` is a working backend — `start(backend: .coreml, modelPath: ...)` boots the HTTP server, serves OpenAI-formatted responses for chat completions, supports streaming via SSE.
- [ ] `DVAIBridgeReactiveState` observable updates on lifecycle transitions.
- [ ] `progressPublisher`, `progressStream`, and `addProgressListener` all observe the same broadcast.
- [ ] `swift-transformers` declared as a SPM dependency at version `from: "0.1.16"` (latest stable as of 3C planning).
- [ ] CI workflow `test-ios-bridge.yml` is green.
- [ ] `smoke-real-models.yml` extended to run the bridge SDK's `RealModelIntegrationTest` when the `SMOKE_COREML_*` and `SMOKE_HF_TOKEN` secrets land in repo settings.
- [ ] CHANGELOG entry for `1.8.0` documents the new SDK.
- [ ] Branch merged to main with a clean rebase + fast-forward.
