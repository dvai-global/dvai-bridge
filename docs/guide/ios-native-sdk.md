# iOS Native SDK (`@dvai-bridge/ios`)

`@dvai-bridge/ios` is the standalone iOS SDK that runs the OpenAI-compatible
local HTTP server *without* Capacitor. Drop it into a SwiftUI / UIKit app,
call `start()`, point your OpenAI client at the returned `baseUrl`.

If you're building a Capacitor app, you don't need this page — see
[Native LLM (Capacitor)](./native-backend.md) instead. This page is for
native iOS apps.

## Install

### Swift Package Manager (recommended)

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/dvai-global/dvai-bridge.git", from: "3.2.0"),
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "DVAIBridge", package: "dvai-bridge"),
        ]
    ),
],
```

Or via Xcode → File → Add Package Dependencies → paste the repo URL.

The product name is `DVAIBridge`. Importing it brings the public API
into scope:

```swift
import DVAIBridge
```

Platform floor: **iOS 18.1 / macOS 14**. iOS 18.1 is the link-time
minimum because `DVAIFoundationCore` weak-links Apple's `FoundationModels`
framework (whose iOS-26 symbols resolve at runtime); macOS 14 is the
floor for the CoreML state-machine API used by `DVAICoreMLCore`.

::: warning Upgrading from v3.1 or earlier
v3.2.0 raised the standalone-package floors for `DVAILlamaCore` +
`DVAISharedCore` from **iOS 14 / macOS 12** to **iOS 17 / macOS 14**
because we migrated the iOS HTTP backbone from Telegraph to
Hummingbird (built on swift-nio) to enable proper SSE streaming
through the offload proxy. The umbrella `DVAIBridge` SDK was already
at iOS 18.1 / macOS 14, so apps consuming the umbrella aren't
affected — but if you depend on `DVAILlamaCore` directly and still
target iOS 14–16, you'll need to either:

  - bump your app's `IPHONEOS_DEPLOYMENT_TARGET` to `17.0`, or
  - pin to `dvai-bridge` `3.1.x` (last release on the iOS 14 floor).

The HTTP server's *public* API is unchanged: `HttpServer.installRoutes`
/ `tryBind` / `stop` keep their signatures. The only behavioural
difference is install-then-bind ordering — Hummingbird requires the
router at `Application` construction time, so call
`installRoutes(...)` *before* `tryBind(...)`. All four bundled
plugin states (`PluginState` / `FoundationPluginState` /
`MLXPluginState` / `CoreMLPluginState`) already follow the new
order; consumers wiring their own backends should mirror it.
:::

### CocoaPods

Add to your `Podfile`:

```ruby
pod 'DVAIBridge', :git => 'https://github.com/dvai-global/dvai-bridge.git', :tag => 'v1.8.0'
```

Then `pod install`.

The CocoaPods build is **feature-asymmetric** with the SwiftPM build —
see [CocoaPods asymmetries](#cocoapods-asymmetries) below for what's
omitted and why. SwiftPM is the primary path; CocoaPods is provided
for shops that haven't migrated off it.

Before installing, the consumer's machine must have the llama.cpp
xcframeworks built — run once in the dvai-bridge repo:

```bash
bash scripts/mac-side-prepare-xcframework.sh
```

This is a 5–15 minute one-time build per submodule SHA bump.

## Quick start

```swift
import DVAIBridge

func startInference() async throws {
    let server = try await DVAIBridge.shared.start(.init(
        backend: .llama,
        modelPath: "/path/to/Llama-3.2-1B-Instruct.Q4_K_M.gguf"
    ))
    print(server.baseUrl)   // e.g. "http://127.0.0.1:38883/v1"
}
```

After `start()` returns, point any OpenAI-compatible client at the
returned `baseUrl`. Streaming SSE works through the same URL.

```swift
let url = URL(string: "\(server.baseUrl)/chat/completions")!
var req = URLRequest(url: url)
req.httpMethod = "POST"
req.setValue("application/json", forHTTPHeaderField: "Content-Type")
req.httpBody = try JSONSerialization.data(withJSONObject: [
    "messages": [["role": "user", "content": "Hello"]],
    "max_tokens": 64,
])
let (data, _) = try await URLSession.shared.data(for: req)
```

When you're done:

```swift
try await DVAIBridge.shared.stop()
```

## Distributed inference (`OffloadConfig`) — v3.0

`OffloadConfig` is opt-in (`enabled: false` by default). When enabled,
the bridge advertises this device on Bonjour
(`_dvai-bridge._tcp`), discovers LAN peers, and can route inference to a
peer that's already loaded the requested model. Pairing requests are
surfaced to the host UI as an `AsyncStream<PairingRequest>`; the user
approves or denies, and the trust relationship persists in
`Application Support/dvai-bridge/pairings.json`.

```swift
import DVAIBridge

func startWithOffload() async throws {
    let server = try await DVAIBridge.shared.start(StartOptions(
        backend: .llama,
        modelPath: "/path/to/Llama-3.2-1B-Instruct.Q4_K_M.gguf",
        offload: OffloadConfig(
            enabled: true,
            discoverLAN: true,
            minLocalCapability: 10,        // fall through to peer below 10 tok/s
            rendezvousUrl: nil,            // set to a wss:// URL for internet path
            knownPeers: [],                // optional pre-known peers
            expireAfterDays: 30            // pairing TTL
        )
    ))
    print(server.baseUrl)
}
```

Surface incoming pairing requests to the user:

```swift
Task.detached {
    for await req in await DVAIBridge.shared.pairingRequests() {
        // Show your UI: "Allow <req.peerDeviceName> to send inference?"
        let approved = await showPairingPrompt(req.peerDeviceName)
        req.respond(approved: approved)
    }
}
```

If the host doesn't respond inside the policy timeout (default 30s),
the request defaults to **deny** — the same safe fallback the JS layer
uses when no `onPairingRequest` callback is supplied.

You can also subscribe to LAN-discovery events:

```swift
if #available(iOS 14.0, *) {
    Task.detached {
        for await event in await DVAIBridge.shared.discoveryEvents() {
            switch event {
            case .peerUp(let peer):    print("up:", peer.deviceName)
            case .peerDown(let id):    print("down:", id)
            case .error(let msg):      print("err:", msg)
            }
        }
    }
}
```

The same on-disk JSON formats are shared with the Node and browser
layers (see `docs/migration/v2.4-to-v3.0.md`), so a Mac app running
both an Electron and an iOS-Catalyst build round-trips one capability
cache and pairing store.

## Backends

| `BackendKind` | Inference engine | Model format | iOS minimum | Notes |
|---|---|---|---|---|
| `.llama` | llama.cpp / Metal | GGUF | 14 (link), 14 (runtime) | Broadest model coverage. |
| `.foundation` | Apple Foundation Models | (no file) | 18.1 (link), 26 (runtime) | Zero-download text on iOS 26+. SwiftPM-only. |
| `.coreml` | CoreML / ANE | `.mlmodelc` directory | 18 (runtime) | Stateful 4-bit Llama-3.2 reference. **Experimental — see [Known issues](#known-issues).** |
| `.mlx` | MLX (Apple Silicon GPU/ANE) | HuggingFace Hub id | 17 (link), Apple Silicon (runtime) | See the [MLX backend page](./mlx-backend.md). SwiftPM-only. |
| `.auto` | Resolve at runtime | Inferred from `modelPath` | — | See [auto-resolution](#auto-resolution-rules) below. |

### Auto-resolution rules

Pass `.auto` and the SDK picks based on `modelPath`:

| `modelPath` | Resolves to |
|---|---|
| ends in `.gguf` | `.llama` |
| ends in `.mlmodelc` / `.mlpackage` | `.coreml` |
| nil + iOS 26+ device | `.foundation` |
| `<owner>/<repo>` style HF id (no extension) | **error** — pass `.mlx` explicitly (see below) |
| ends in `.task` / `.litertlm` | error (Android-only formats) |

`.mlx` is *not* auto-resolved from a HuggingFace id because not every
HF id is an MLX checkpoint. Pass `.mlx` explicitly when you mean it.

## SwiftUI integration: `DVAIBridgeReactiveState`

`DVAIBridge.shared.reactive` returns a `@MainActor`-isolated reactive
state object you can pin into a SwiftUI view:

```swift
struct ContentView: View {
    @StateObject private var state = DVAIBridge.shared.reactive

    var body: some View {
        if state.isReady {
            Text("Server: \(state.baseUrl ?? "—")")
            Text("Backend: \(state.currentBackend?.rawValue ?? "—")")
        } else {
            ProgressView()
        }
    }
}
```

Published properties: `isReady`, `baseUrl`, `port`, `currentBackend`,
`lastProgress`. They update on the main actor as the bridge's lifecycle
advances.

### CocoaPods: no `ObservableObject`

The SwiftUI integration above is **SwiftPM-only**. Under CocoaPods,
`DVAIBridgeReactiveState` does not conform to `ObservableObject`
(see [CocoaPods asymmetries](#cocoapods-asymmetries) for the reason).
CocoaPods consumers can subscribe to the always-available
`stateChanges` publisher instead:

```swift
import Combine

let cancellable = DVAIBridge.shared.reactive.stateChanges
    .receive(on: DispatchQueue.main)
    .sink { _ in
        // re-render off DVAIBridge.shared.reactive.<prop>
    }
```

## Progress observation

Three equivalent ways to observe lifecycle progress events
(`load → ready` / `download → verify → load → ready` / etc.):

```swift
// Combine publisher
let cancellable = DVAIBridge.shared.progressPublisher.sink { event in
    print(event.phase, event.percent ?? -1)
}

// AsyncStream
Task {
    for await event in DVAIBridge.shared.progressStream {
        print(event.phase, event.percent ?? -1)
    }
}

// Callback
let token = DVAIBridge.shared.addProgressListener { event in
    print(event.phase)
}
// later: token.cancel()
```

All three observe the same underlying broadcaster — picking one is
preference, not architecture.

## Model download / cache

The bridge wraps a `ModelDownloader` for sha256-verified GGUF/.task/etc.
caching:

```swift
let result = try await DVAIBridge.shared.downloadModel(.init(
    url: URL(string: "https://example.com/model.gguf")!,
    sha256: "abc123…"
))
print(result.path, result.cached)
```

Plus `listCachedModels()`, `deleteCachedModel(filename:)`, and
`cacheDir()` for cache management.

CoreML and MLX backends manage their model caches independently
(CoreML uses local `.mlmodelc` directories; MLX uses HuggingFace Hub
cache). The methods above target llama.cpp's GGUF cache only.

## CocoaPods asymmetries

The single-pod CocoaPods build collapses every Swift module in the SDK
into one `DVAIBridge` Swift module. That's incompatible with three
SwiftPM-only patterns:

1. **`DVAIBridgeReactiveState` doesn't conform to `ObservableObject`
   under CocoaPods.** Xcode 26 / iOS 26 SDK's static linker emits an
   implicit link directive for `SwiftUICore` (a private framework
   non-Apple products cannot link) for any module that conforms a type
   to `ObservableObject`, even if the module never imports SwiftUI.
   CocoaPods bundles the whole pod into one Swift module, so the
   trigger lands on every consumer's link line.
   **Workaround**: subscribe to `stateChanges` (a `Combine` publisher)
   instead of using `@StateObject` / `@ObservedObject`.
2. **The `.foundation` backend is SwiftPM-only.** `import FoundationModels`
   emits implicit autolink directives for the same family of private
   frameworks (`SwiftUICore`, `UIUtilities`, `CoreAudioTypes`).
   Selecting it under CocoaPods throws `DVAIBridgeError.backendUnavailable(.foundation, …)`.
3. **The `.mlx` backend is SwiftPM-only.** `mlx-swift-lm`'s transitive
   Swift packages don't publish CocoaPods specs. Selecting `.mlx` under
   CocoaPods throws `DVAIBridgeError.backendUnavailable(.mlx, …)`.

CocoaPods consumers can use `.llama` and `.coreml` backends; together
those cover the broad on-device-LLM use case. The other two are
recommended-SwiftPM features.

## Errors

`DVAIBridgeError` is the public error enum:

| Case | When |
|---|---|
| `.alreadyStarted(currentBackend:baseUrl:)` | `start()` called twice without `stop()`. |
| `.configurationInvalid(reason:)` | Bad `DVAIBridgeConfig` (e.g. unknown modelPath extension under `.auto`). |
| `.modelLoadFailed(reason:)` | Backend rejected the model file. |
| `.backendUnavailable(BackendKind, reason:)` | Backend can't run in this build/env (CocoaPods .mlx, iOS-25 .foundation, etc.). |
| `.backendError(underlying:)` | Generic backend failure (e.g. server bind). |
| `.checksumMismatch` | `downloadModel` sha256 didn't match. |
| `.downloadFailed(reason:)` | `downloadModel` networking failure. |

## Tests

If you want to run the SDK's own tests against real models, populate
`scripts/smoke.local.env` (gitignored) and use `xcodebuild test` against
the `DVAIBridge-Package` scheme. See `[1.8.0]` in the CHANGELOG for the
env-var list and the public reference checkpoints used.

## Known issues

### CoreML backend: IRValue crash at first prediction (experimental)

The `.coreml` backend is shipped in v2.0.0 as **experimental**. Model
load + tokenizer load + HTTP server boot all succeed against the
reference checkpoint
[`finnvoorhees/coreml-Llama-3.2-1B-Instruct-4bit`](https://huggingface.co/finnvoorhees/coreml-Llama-3.2-1B-Instruct-4bit).
However, the first call to `MLModel.prediction(from:using:)` crashes
inside CoreML's C++ IR layer with:

```
Error: Cannot retrieve vector from IRValue format int32
```

The crash is a process exit (not a Swift `Error` you can catch) and
reproduces on **both** iOS Simulator and macOS-native, which rules out
the previously-suspected simulator-only Espresso translation
limitation. The integration test (`testCoreMLBackendIntegration`) is
gated off via `XCTSkip` until the cause is understood — live debug on
a physical iOS device with Instruments is the next step.

**What works:**
- Model + tokenizer file load via `DVAIBridge.shared.start(.init(backend: .coreml, ...))`
- HTTP server bind + `/v1/models` listing

**What doesn't (yet):**
- `/v1/chat/completions` against the reference checkpoint (crashes)

**If you want to experiment:** any pre-converted `.mlmodelc` Llama-style
stateful checkpoint may exhibit the same issue — this isn't specific
to the finnvoorhees mirror. Until the bug is fixed, prefer `.llama` or
`.mlx` for production iOS LLM workloads.

This is tracked as the top-priority CoreML follow-up under "Known
Phase 3D follow-ups" in [CHANGELOG.md](../../CHANGELOG.md).

## Outgoing offload (v3.2)

When `OffloadConfig(enabled: true)` is passed to
`DVAIBridge.shared.start(_:)`, a Hummingbird/swift-nio pre-routing
proxy binds the public port and decides per-request whether to
serve the request locally or forward it to a paired peer. **No
consumer code change** — your existing OpenAI client points at
`server.baseUrl` exactly as before. SSE responses stream through
the proxy chunk-by-chunk so consumer apps see tokens arrive
incrementally, matching the Android Ktor and TS proxy paths.

```swift
let server = try await DVAIBridge.shared.start(StartOptions(
    backend: .auto,
    modelPath: "/path/to/model.gguf",
    offload: OffloadConfig(enabled: true)
))
// Use server.baseUrl with URLSession / any OpenAI client.
```

### Pre-init hardware assessment

Before any model download or backend init:

```swift
let assessment = DVAIBridge.shared.assessHardware(
    hardwareMinimum: 3.0,
    minLocalCapability: 10.0
)
switch assessment.mode {
case .ok:           try await DVAIBridge.shared.start(options)
case .offloadOnly:  try await DVAIBridge.shared.start(options)  // SDK skips backend
case .tooWeak:      showCustomNotSupportedAlert(assessment.reason)
}
```

The SDK never shows UI for hardware decisions — your app does.
See the [distributed-inference guide](./distributed-inference.md#v32--per-sdk-outgoing-offload-routing)
for the full `assessHardware()` contract.

## Reference

- [Public Swift API](../reference/api.md)
- [MLX backend specifics](./mlx-backend.md)
- [Backends comparison](./backends.md)
