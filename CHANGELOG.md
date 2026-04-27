# Changelog

All notable changes to this project are documented here. This project
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.8.0] — 2026-04-27

Phase 3C — iOS Native SDK: standalone `@dvai-bridge/ios` package wrapping
`DVAILlamaCore` + `DVAIFoundationCore` + a fully-implemented
`DVAICoreMLCore` + a new `DVAIMLXCore`. First non-Capacitor consumer
surface for the OpenAI-compatible HTTP server on iOS, with **four**
production-grade backends.

### Added (post-initial-Phase-3C, same release)

- **MLX backend (4th backend)** — new `@dvai-bridge/ios-mlx-core` package
  wrapping [`mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm)
  for Apple-Silicon GPU + Neural Engine LLM inference. Loads MLX-converted
  HuggingFace checkpoints via the simple `loadModelContainer(id:)` API
  (HF Hub-cached, e.g. `mlx-community/Llama-3.2-1B-Instruct-4bit`).
  iOS 17+ / macOS 14+ at link time; Apple-Silicon-only at runtime.
  - `BackendKind.mlx` / `BackendInstance.mlx` cases wired into DVAIBridge.
  - SwiftPM-only — `mlx-swift-lm`'s transitive Swift packages don't
    publish CocoaPods specs, so selecting `.mlx` under a CocoaPods build
    throws `DVAIBridgeError.backendUnavailable` with a clear message.
- **`@dvai-bridge/capacitor-mlx`** Capacitor plugin mirroring the
  `capacitor-foundation` pattern — installs a `DVAIBridgeMLX` native
  plugin that forwards to `MLXPluginState`. The umbrella
  `@dvai-bridge/capacitor` shim's `CapacitorBackend` type-union now
  includes `"mlx"` and the dispatcher routes accordingly. Android
  selecting `.mlx` returns the same `iOS-only` error as `.foundation`.
- **CoreML integration test now runs on iOS Simulator + macOS native**
  — the test was rewritten to download the `.mlmodelc/` directory
  file-by-file from a public HF mirror (`finnvoorhees/coreml-Llama-3.2-1B-Instruct-4bit`)
  rather than zip-and-unzip, so the iOS Simulator's lack of `Process`
  is no longer a blocker. The public mirror also bundles
  `tokenizer.json` + `tokenizer_config.json`, so we no longer need
  the gated `meta-llama/Llama-3.2-1B-Instruct` repo or `SMOKE_HF_TOKEN`.
  - On iOS Simulator the test still hard-skips when the simulator's
    CoreML runtime fails the stateful 4-bit MIL→EIR translation
    (Espresso status=-14, a known simulator constraint that doesn't
    repro on macOS native or real devices).
  - Single env var: `SMOKE_COREML_MODEL_BASE_URL`. The old four
    `SMOKE_COREML_*` + `SMOKE_HF_TOKEN` vars are no longer needed.

### Documentation

- `docs/guide/native-backend.md` updated:
  - Architecture diagram now shows 5 packages (capacitor + 4 backends).
  - "What runs on which platform" table includes `capacitor-mlx`.
  - New "MLX backend" section covering the HF-id `modelPath` pattern,
    Apple-Silicon-at-runtime constraint, the SwiftPM-vs-CocoaPods
    asymmetry, and the embeddings-not-supported caveat.

### Known Phase 3D follow-ups

- **Mac Catalyst destination support.** Upstream's `llama.cpp/build-xcframework.sh`
  hardcodes the 4 platforms it builds (iOS / macOS / visionOS / tvOS) and
  doesn't include Mac Catalyst. Adding a Catalyst slice means either
  patching upstream every submodule bump (fragile) or maintaining our
  own ~150-line parallel build pipeline that replicates upstream's
  `setup_framework_structure` + `combine_static_libraries` for catalyst.
  Real iOS devices + iOS Simulator (now post-multi-file refactor) cover
  the vast majority of test scenarios; Catalyst is deferred until there's
  a consumer asking for it.



### Added

- `@dvai-bridge/ios` npm package with SPM `Package.swift` at the package
  root and a `DVAIBridge.podspec` for CocoaPods consumers.
- `DVAIBridge.shared` singleton actor exposing the 8-method public API:
  `start`, `stop`, `status`, `addProgressListener`, `downloadModel`,
  `listCachedModels`, `deleteCachedModel`, `cacheDir`.
- `BackendKind` enum (`.auto`, `.llama`, `.foundation`, `.coreml`) with
  `auto`-resolution at runtime based on modelPath extension + iOS 26+
  availability.
- `DVAIBridgeReactiveState` `@MainActor` `ObservableObject` for SwiftUI
  consumers — `isReady`, `baseUrl`, `port`, `currentBackend`,
  `lastProgress` published properties wired to the bridge's lifecycle
  + progress events via a per-instance registry.
- Three observation surfaces for `ProgressEvent`: Combine
  `progressPublisher`, `progressStream` (`AsyncStream`), and
  `addProgressListener(_:)` callback. All three observe the same source.
- **Full CoreML LLM backend** (`DVAICoreMLCore`):
  - `MLModel` + `MLState` for KV-cached autoregressive decoding
    (iOS 18+ / macOS 15+).
  - `swift-transformers` 1.3.0 (HuggingFace) for tokenization +
    `applyChatTemplate(...)` across Llama / Gemma / Phi families.
  - Greedy + temperature + top-p + top-k sampling.
  - Streaming via SSE (`AsyncStream<String>` produced by
    `CoreMLGenerator.generateStream(...)`).
  - OpenAI ChatCompletion / Completion / Models JSON output via
    `CoreMLHandlers`, served on Telegraph with the same port-fallback
    + CORS plumbing as the llama core.
  - Reference checkpoint: `apple/coreml-Llama-3.2-1B-Instruct-4bit`
    (others should work if the input/output tensor names match).
- `RealModelIntegrationTest` — three end-to-end tests against real models,
  one per backend, gated on env-var availability:
  - `testLlamaBackendIntegration` (uses Phase 2C's existing
    `SMOKE_MODEL_*` env vars; verified passing on iOS Simulator with
    Llama-3.2-1B Q4_K_M).
  - `testFoundationBackendIntegration` (iOS 26+ runtime; no model file).
  - `testCoreMLBackendIntegration` (new `SMOKE_COREML_*` env vars +
    `SMOKE_HF_TOKEN` for the gated meta-llama tokenizer; the unzip step
    requires `Process` so the iOS-Simulator path skips with a Phase 3D
    follow-up note — exercise via Mac Catalyst destination, or land an
    in-process unzip).
- `test-ios-bridge.yml` CI workflow running XCTest for the
  `DVAIBridge-Package` scheme on the self-hosted Mac runner.
- Public `DVAIHandlers` protocol + `HandlerContext` + `HandlerResponse` +
  `HttpServer.tryBind(...)` / `installRoutes(...)` exposed from
  `DVAILlamaCore` (surgical visibility bumps; no logic changes).
- `ModelDownloader.DownloadError` exposed as `public` so cross-module
  consumers (DVAIBridge) can pattern-match `.checksumMismatch` instead
  of grepping the localized error string.

### CocoaPods packaging

- **`pod lib lint DVAIBridge.podspec` — passes** on Xcode 26 / iOS 26 SDK.
  The podspec is now a single-target spec that mirrors our SwiftPM module
  graph by vendoring the upstream HuggingFace stack and gating
  cross-target imports behind `#if !COCOAPODS`.
- Vendored under `packages/dvai-bridge-ios/Vendor/swift-transformers/`
  (gitignored only at the level of build output, but source tree is
  checked in):
  - `huggingface/swift-transformers @ 1.3.0` — `Tokenizers` + `Hub`
    (the upstream `Hub/HubApi.swift` is replaced by a stripped 80-line
    variant that drops Crypto / HuggingFace / yyjson / EventSource /
    swift-xet / swift-crypto code paths we never call. JSON parsing
    backed by `Foundation.JSONSerialization`).
  - `huggingface/swift-jinja @ 2.3.5`.
  - `apple/swift-collections @ 1.4.1` — `OrderedCollections` +
    `InternalCollectionsUtilities`.
  - Apache-2.0 LICENSE preserved as
    `Vendor/swift-transformers/LICENSE-<dep>`.
- New helper scripts:
  - `scripts/wrap-cocoapods-imports.py` — idempotent post-vendor pass
    that wraps every cross-target `import` with `#if !COCOAPODS` so the
    same source tree compiles cleanly under both SwiftPM (which pulls
    the real upstream packages) and CocoaPods (which collapses the pod
    into a single `DVAIBridge` Swift module).
  - `scripts/patch-cocoapods-vendor.py` — idempotent patches that
    rename collisions (Tokenizers' `Decoder` → `TokenizerStepDecoder`,
    Jinja's `Value` → `JinjaValue`) so the flattened CocoaPods module
    has no shadowing.
- `mac-side-prepare-xcframework.sh` is unchanged; the podspec uses a
  `prepare_command` that copies the built `llama.xcframework` /
  `mtmd.xcframework` and the sibling-package source dirs into a
  pod-local `Frameworks/` and `Sources/_external/` so CocoaPods'
  globbing (which doesn't follow `..` paths) can find them.

### CocoaPods vs SwiftPM asymmetries (intentional)

The two distribution channels are not symmetric. SwiftPM remains the
primary path; CocoaPods is a best-effort wrapper for shops on that
toolchain.

- **`DVAIBridgeReactiveState` is not an `ObservableObject` under
  CocoaPods.** Xcode 26 / iOS 26 SDK's static linker emits an implicit
  link directive for `SwiftUICore` (a private framework non-Apple
  products cannot link) for any module that conforms a type to
  `ObservableObject`, even if the module never imports SwiftUI.
  CocoaPods bundles the whole pod into one Swift module, so the
  trigger lands on every consumer's link line and pod lib lint /
  release builds fail with `cannot link directly with 'SwiftUICore'`.
  SwiftPM is unaffected because the ObservableObject conformance ends
  up in a library that's link-resolved at the consumer's app target,
  where SwiftUICore access *is* allowed.
  In place of the conformance + `@Published` wrappers, CocoaPods
  consumers get a `stateChanges: AnyPublisher<Void, Never>` that
  fires on every property change. Pattern:
  ```
  .onReceive(DVAIBridge.shared.reactive.stateChanges) { _ in
      // re-render off DVAIBridge.shared.reactive.<prop>
  }
  ```
  See [ReactiveState.swift](packages/dvai-bridge-ios/ios/Sources/DVAIBridge/ReactiveState.swift) for the full doc-comment rationale.
- **The Foundation Models backend is SwiftPM-only.** `import
  FoundationModels` emits implicit autolink directives for the same
  family of private frameworks (`SwiftUICore`, `UIUtilities`,
  `CoreAudioTypes`) that CocoaPods consumers cannot link.
  `BackendKind.foundation` remains in the public API for symmetry, but
  selecting it under a CocoaPods build throws
  `DVAIBridgeError.backendUnavailable(.foundation, reason: "...use
  SwiftPM if your app needs the Foundation backend...")`.
  CocoaPods consumers get `.llama` and `.coreml` which together cover
  the broad on-device-LLM use case.
- **Telegraph version differs by channel.** SwiftPM resolves Telegraph
  `0.40.0` (latest GitHub tag); CocoaPods resolves `~> 0.30` (latest
  on CocoaPods trunk — Building42 hasn't published 0.40+ to trunk).
  Our usage only touches stable core types
  (`Server` / `HTTPRequest` / `HTTPResponse` / `HTTPStatus` /
  `HTTPHeaders`) which are unchanged across the 0.30→0.40 range.

### Verified

- 44 XCTest cases pass on iOS Simulator (42 unit + 1 llama
  integration end-to-end + 1 expected skip for Foundation Models which
  needs iOS 26+ runtime).
- CoreML real-model integration test wiring is verified end-to-end —
  download, sha256 verify, unzip, tokenizer load, server start, chat
  completion — but currently SKIPS at runtime with a clear message
  because Apple removed
  `apple/coreml-Llama-3.2-1B-Instruct-4bit` from HuggingFace
  (its API now returns "Repository not found"). The test passed
  end-to-end against this exact checkpoint at the time the test was
  authored (Phase 3C development). When a replacement public
  CoreML-converted Llama-style stateful checkpoint becomes available,
  point `SMOKE_COREML_MODEL_URL`/`SMOKE_COREML_MODEL_SHA256` at it.
  Test now hard-skips with an explanatory message if the model URL
  returns 4xx, rather than failing with a confusing "sha256 mismatch"
  on the tiny error response body.
  CoreML still also skips on iOS Simulator (Process unavailable for
  unzip) and on Mac Catalyst (xcframework lacks a Mac Catalyst slice
  — Phase 3D).
- `pod lib lint DVAIBridge.podspec --allow-warnings` passes on Xcode
  26.4 / CocoaPods 1.15.2.
- Existing Capacitor tests + Phase 3A/3B test suites unaffected.

### Manual setup for the CoreML integration test (first-time only)

The CoreML backend's integration test downloads ~700 MB of model
weights + a few MB of tokenizer config. The user populates
`scripts/smoke.local.env` with:

```
SMOKE_COREML_MODEL_URL=https://huggingface.co/apple/coreml-Llama-3.2-1B-Instruct-4bit/resolve/main/StatefulModel.mlmodelc.zip
SMOKE_COREML_MODEL_SHA256=<sha256 of the zip>
SMOKE_COREML_TOKENIZER_URL=https://huggingface.co/meta-llama/Llama-3.2-1B-Instruct/resolve/main/tokenizer.json
SMOKE_COREML_TOKENIZER_SHA256=<sha256 of tokenizer.json>
SMOKE_HF_TOKEN=hf_<your-token>      # for the gated meta-llama repo
```

As of 2026-04 BOTH the Apple CoreML model
(https://huggingface.co/apple/coreml-Llama-3.2-1B-Instruct-4bit) and
the Llama-3.2 tokenizer
(https://huggingface.co/meta-llama/Llama-3.2-1B-Instruct) are gated HF
repos. The user must accept the license terms on each repo once and
create a read-only access token at
https://huggingface.co/settings/tokens. The same token is used for both
downloads.

After accepting the license and downloading the
`StatefulModel.mlmodelc.zip` once with auth, compute its sha256 with
`shasum -a 256 StatefulModel.mlmodelc.zip` and put that hash into
`SMOKE_COREML_MODEL_SHA256` (the SHA changes if Apple republishes).

## [1.7.0] — 2026-04-26

Phase 3A Foundation + Phase 3B LiteRT-LM Migration: extracts each
Capacitor plugin's portable native code into separate `*-core` packages
so the same source feeds both the Capacitor wrapper and the upcoming
standalone native SDKs (iOS Swift Package Manager, Android AAR, .NET
NuGet, RN, Flutter). MediaPipe Android backend migrates from the
deprecated `tasks-genai` SDK to LiteRT-LM `0.10.2`.

### Added

- Four new `*-core` packages, each Capacitor-free and consumable
  standalone:
  - `@dvai-bridge/ios-llama-core` — pure Swift / ObjC++ llama.cpp core
    (Telegraph HTTP server, OpenAI handlers, model downloader,
    content-parts translator, ObjC++ bridge into llama.cpp + mtmd)
  - `@dvai-bridge/ios-foundation-core` — pure Swift Apple
    FoundationModels core (link-time iOS 18.1, runtime iOS 26+)
  - `@dvai-bridge/android-llama-core` — pure Kotlin + JNI llama.cpp
    core (Ktor HTTP server, NDK CMake build of llama.cpp, JNI bridge)
  - `@dvai-bridge/android-mediapipe-core` — pure Kotlin LiteRT-LM core
- 16 KB Android page-size alignment baked into the llama-core NDK build
  (`-Wl,-z,max-page-size=16384`), with a CI verification step that
  runs `objdump -p` on every produced `.so` and fails the build on
  alignment regression. Compatible with Google Play's 2025 mandate.
- CI workflows split per-package: each Android JVM workflow runs
  `core-jvm-test` then `wrapper-jvm-test` (`api project(...)` re-export
  means the wrapper transitively rebuilds the core anyway, but split
  reporting attributes test failures to the right package).
- `scripts/verify-cap-sync.sh` — end-to-end regression test that boots
  a throwaway Capacitor host app, installs all plugins + cores via
  `file:` paths, runs `npx cap sync`, and asserts both Android and iOS
  resolve cleanly against the new package layout.
- `docs/development/litert-lm-migration-notes.md` — Phase 3B inventory
  artifact with side-by-side `tasks-genai` → `litertlm-android` API
  mapping, behavioral deltas, and risk register.

### Changed

- `@dvai-bridge/capacitor-llama`, `@dvai-bridge/capacitor-foundation`,
  and `@dvai-bridge/capacitor-mediapipe` are now thin Capacitor wrappers
  that depend on their respective `*-core` packages. Host apps must
  install both the wrapper and its core(s) — the wrapper's
  `package.json` lists them as `peerDependencies` and the install
  error is actionable.
- Android Kotlin package id renamed: `co.deepvoiceai.dvaibridge.*`
  → `co.deepvoiceai.bridge.*` across the entire Android tree (drops the
  redundant "dvai" segment that's already in the org name and the npm
  package names). Core sub-packages are `co.deepvoiceai.bridge.*.core`;
  wrapper packages are `co.deepvoiceai.bridge.*`. JNI symbols
  regenerate to match (`Java_co_deepvoiceai_dvaibridge_llama_*` →
  `Java_co_deepvoiceai_bridge_llama_core_*`). Capacitor plugin IDs
  (`@CapacitorPlugin(name = "DVAIBridgeLlama")`) are unchanged.
- llama.cpp git submodule relocated from
  `packages/dvai-bridge-capacitor-llama/native/llama.cpp` to
  `packages/dvai-bridge-android-llama-core/android/src/main/cpp/native/llama.cpp`.
  iOS xcframework binary targets and `scripts/mac-side-prepare-xcframework.sh`
  follow.
- `MediaPipeBridgeApi.completePrompt` and `streamPrompt` now take
  `List<ByteArray>` instead of `List<MPImage>`, so the bridge interface
  no longer leaks MediaPipe types. Internal-only; no Capacitor / public
  JS API impact.
- `@dvai-bridge/android-mediapipe-core` migrated from
  `com.google.mediapipe:tasks-genai:0.10.33` (`@Deprecated` since
  0.10.27) and `tasks-core:0.10.33` to a single artifact
  `com.google.ai.edge.litertlm:litertlm-android:0.10.2`. Class renames:
  `LlmInference` → `Engine`, `LlmInferenceSession` → `Conversation`,
  `MPImage` → `Content.ImageBytes(ByteArray)`. The "add chunks then
  generate" call sequence becomes a single `sendMessage(Contents.of(...))`.
  Same handler behaviour; same Capacitor JS contract.
- `PluginState`'s public surface in both `android-llama-core` and
  `android-mediapipe-core` switched from Capacitor's `JSObject` to
  plain `Map<String, Any?>`. The wrapper's `Plugin.kt` translates
  `JSObject ↔ Map` at the JS-bridge boundary via small private helpers.

### Removed

- `tasks-genai` and `tasks-core` Maven dependencies.
- `MPImage` references from public bridge interfaces.
- Capacitor `JSObject` references from core packages.

### Verified

- TS suite: 104 / 104.
- iOS XCTest (full suite, real-model smoke skipped): llama-core 64,
  foundation-core 10, capacitor-llama 1, capacitor-foundation 1.
- Android JVM: llama-core 53+ (BUILD SUCCESSFUL), mediapipe-core 26,
  capacitor-llama 1, capacitor-mediapipe 2. mediapipe-core's 26 tests
  all pass against the LiteRT-LM-backed bridge implementation.

## [1.6.0] — 2026-04-24

Phase 0 — Transport Abstraction: extracts the OpenAI-compatible handlers
into a transport-agnostic module and adds a real HTTP server transport
for Node / Electron. The browser path (MSW) is behaviorally unchanged.

### Added
- `transport` config option: `"auto" | "msw" | "http" | "none"`.
- HTTP transport for Node and Electron main process (base port `38883`,
  +1 fallback up to 16 attempts on `EADDRINUSE`).
- `dvai.baseUrl` / `dvai.port` fields.
- `dvai.getBaseUrl()` / `dvai.getPort()` / `dvai.getActiveTransport()` methods.
- New transport-agnostic handler module under `src/handlers/`
  (`handleChatCompletion`, `handleCompletion`, `handleEmbeddings`,
  `handleModels` as pure `(body, ctx) => Response` functions).
- CORS + Private Network Access headers on HTTP transport responses
  (enables HTTPS pages calling loopback without Chrome/Edge PNA blocks).
- `BASE_PORT` and `MAX_PORT_ATTEMPTS` exported constants from
  `@dvai-bridge/core` (via `./transports`).
- `httpBasePort`, `httpMaxPortAttempts`, `corsOrigin` config options.
- Root-level `examples/` directory (`web-react`, `node-langchain`) —
  moved out of the published package path.
- `files` allowlist on all package `package.json` files — prevents
  `src/`, `example/`, and test files from accidentally shipping to npm.

### Changed
- `mockUrl` is now MSW-specific. Under HTTP transport, it is ignored
  with a one-time console warning. Read `dvai.baseUrl` for the real URL.
- `DVAI` in Node now auto-starts a real HTTP server on `initialize()`
  (previously crashed trying to register MSW without
  `navigator.serviceWorker`).
- Internal `buildMswHandlers` refactored into pure handler functions
  plus a thin MSW transport adapter (`MswTransport` class).
- `HandlerContext.backend` is now exposed via a getter so mid-request
  recovery can swap the backend instance and subsequent handler calls
  see the new one. Not a user-facing change.

### Removed
- `packages/dvai-bridge-core/example/langchain-node-example.js` standalone
  snippet (replaced by the runnable `examples/node-langchain/` project).
- `DVAI.getWorker()` method (the MSW worker is now an implementation
  detail of `MswTransport`; read `dvai.getBaseUrl()` instead).

### Fixed
- `new DVAI()` in plain Node no longer crashes — auto-resolves to the
  new HTTP transport.

### Migration guide: 1.5.x → 1.6.0

**Browser consumers (React / Vanilla):** no action required.
`new DVAI({})` continues to use MSW in browsers with identical behavior.

**Node / Electron consumers:** `DVAI` now auto-boots an HTTP server at
`http://127.0.0.1:38883/v1`. Read `dvai.baseUrl` and pass it to your
OpenAI SDK:

```javascript
const dvai = new DVAI({ backend: "transformers" });
await dvai.initialize();
// dvai.baseUrl === "http://127.0.0.1:38883/v1" (or 38884, 38885, ...)

const openai = new OpenAI({ baseURL: dvai.baseUrl, apiKey: "ignored" });
```

If you want the old direct-inference-only behavior (no transport),
pass `transport: "none"` explicitly, or keep using `serviceWorkerUrl: ""`.

**Custom `mockUrl` + HTTP:** `mockUrl` is ignored under HTTP transport.
If you need a specific URL shape, stay on MSW (`transport: "msw"`,
browser only), or read `dvai.baseUrl` at runtime.

**Removed `getWorker()`:** if you depended on direct access to the MSW
worker instance, that's no longer exposed. Use `dvai.baseUrl` for the
endpoint URL, or `dvai.getActiveTransport()` to check which transport
is active.
