# Changelog

All notable changes to this project are documented here. This project
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
