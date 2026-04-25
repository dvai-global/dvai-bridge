# Phase 1 — Capacitor Multimodal & Embedded HTTP Server

**Status:** Draft — awaiting review
**Date:** 2026-04-25
**Scope:** Three new Capacitor backend plugins + JS routing shim + DVAI core integration. Replaces the Phase 0 `NativeBackend` / `llama-cpp-capacitor` path.
**Phase 3 launch dependency:** Phase 1 is the mobile pillar of the Phase 3 launch story.

---

## 1. Goals

1. Stand up first-party Capacitor plugins for on-device inference: `capacitor-llama` (cross-platform), `capacitor-foundation` (iOS-only), `capacitor-mediapipe` (Android-only).
2. Each plugin embeds a real HTTP server in the native layer (Telegraph for iOS, Ktor for Android), bound to `127.0.0.1` with port-fallback from `38883`.
3. Native handlers (Swift + Kotlin) reimplement Phase 0's four pure-TS handlers — same OpenAI HTTP contract, no JS↔native bridge per request.
4. Multimodal pass-through: OpenAI content parts (text, image, audio) translated into whatever the loaded model + backend natively supports.
5. Shed the `llama-cpp-capacitor` peer dep; delete `NativeBackend.ts`.
6. Optional `downloadModel()` helper for resumable, checksum-verified GGUF downloads.
7. Self-hosted GitHub Actions runner on the developer's MacBook for free, fast, parity-enforcing CI.

## 2. Non-goals (Phase 1)

- No React Native or Flutter dedicated wrappers (deferred to Phase 4).
- No `capacitor-coreml` plugin — Apple's recommended LLM path on iOS is Foundation Models, not raw CoreML.
- No curated model catalog (no built-in model URLs) — the developer supplies the URL + sha256.
- No multi-file model batching or model-format auto-conversion.
- No background-execution privileges — HTTP server lives only as long as the foreground app process.
- No retry / fallback orchestration across plugins (developer composes if needed).
- No `GET /_debug/recent-requests` endpoint — deferred to a coordinated debug surface near Phase 3.
- No HTTPS on loopback (cleartext only — Phase 0 rationale, applies here too).

## 3. Architecture

### 3.1 The pivot

**Phase 0 path on Capacitor (deleted):** the webview's JS calls `dvai.chatCompletion()` → `NativeBackend.chatCompletion()` → `llama-cpp-capacitor` plugin → native llama.cpp via JS↔native bridge per request.

**Phase 1 path:** the webview's JS calls `new DVAI({}).initialize()`. DVAI's `selectTransport` resolves to a new `"capacitor"` transport, which calls `@dvai-bridge/capacitor`'s `start()`. The Capacitor plugin's native code spawns a real HTTP server on `127.0.0.1:38883` (with fallback), loads llama.cpp / Foundation Models / MediaPipe LLM, and returns the bound port to JS. From then on, every OpenAI request from the webview goes via loopback HTTP to the native server — no JS↔native bridge per request.

### 3.2 Three tenets

1. **Native HTTP server is the single contract.** Webview JS, host-app native code, and any external OpenAI SDK all see the same `/v1/*` endpoints over loopback. After `start()` resolves, the JS↔native Capacitor bridge mediates only lifecycle (`start`, `stop`, `status`, `progress`).

2. **Backend plugins are interchangeable.** Three ship in Phase 1; more can join later. Each native plugin registers under its own Capacitor plugin ID (`DVAIBridgeLlama`, `DVAIBridgeFoundation`, `DVAIBridgeMediaPipe`); the JS shim routes by the developer-supplied `backend` config.

3. **Transparent-pipe for modalities.** The library does not implement modality pipelines. OpenAI content parts (text, image, audio) translate into whatever the loaded model + backend natively supports. If unsupported, return a clear 400. No Whisper-chaining, no format alchemy.

### 3.3 Layered package architecture

```
┌──────────────────────────────────────────────────┐
│  Webview (Capacitor host app's HTML/JS)          │
│  const dvai = new DVAI({ … });                   │
│  await dvai.initialize();                        │
│  const openai = new OpenAI({                     │
│    baseURL: dvai.baseUrl, … });                  │
└────────────────┬─────────────────────────────────┘
                 │ fetch http://127.0.0.1:38883/v1/...
                 ▼
┌──────────────────────────────────────────────────────────────┐
│  Backend plugin (one of three, picked at runtime)            │
│  ├── @dvai-bridge/capacitor-llama                            │
│  ├── @dvai-bridge/capacitor-foundation  (iOS only)           │
│  └── @dvai-bridge/capacitor-mediapipe   (Android only)       │
│                                                              │
│  Each ships native HTTP server (Telegraph / Ktor),           │
│  4 native handlers (Swift / Kotlin), backend bridge.         │
└─────────────────┬────────────────────────────────────────────┘
                  │ Capacitor JS bridge — lifecycle only
                  │ start() / stop() / status / progress
                  ▼
┌──────────────────────────────────────────────────────────────┐
│  @dvai-bridge/capacitor  (JS routing shim, ~150 LOC)         │
│  • DVAIBridge.start({ backend: "llama" | "foundation"        │
│                         | "mediapipe", … })                  │
│  • Dispatches to the native plugin matching `backend`        │
│  • DVAIBridge.downloadModel(...) — resumable + checksum      │
└─────────────────────────┬────────────────────────────────────┘
                          ▲
                          │ optional integration
                          │
┌──────────────────────────────────────────────────────────────┐
│  @dvai-bridge/core  (Phase 0)                                │
│  • New "capacitor" transport in selectTransport()            │
│  • When auto-detected on Capacitor, calls @dvai-bridge/      │
│    capacitor's start() and uses returned URL as baseUrl      │
│  • NativeBackend.ts is DELETED                               │
└──────────────────────────────────────────────────────────────┘
```

### 3.4 Dependency graph

- `@dvai-bridge/core` → optional peer-dep on `@dvai-bridge/capacitor`. Browser/Node consumers don't pull it in.
- `@dvai-bridge/capacitor` → no native code, no peer-dep on backend plugins. Uses Capacitor's `registerPlugin('PluginName')` to dynamically resolve native plugins at runtime; emits a clear error if the requested backend's plugin is missing.
- Each backend plugin → peer-dep on `@dvai-bridge/capacitor` for shared types.

Each backend plugin self-contained: HTTP server bootstrap and dispatch are duplicated (~150 LOC × 2 platforms × 3 plugins ≈ 600-1000 LOC of duplication). Trade documented; refactor candidate for Phase 2 if maintenance pain materializes.

## 4. Repository / package additions

```
packages/
├── dvai-bridge-core/                    (existing — modified)
├── dvai-bridge-react/                   (existing — unchanged)
├── dvai-bridge-vanilla/                 (existing — unchanged)
├── dvai-bridge-capacitor/               NEW — pure-TS routing shim
├── dvai-bridge-capacitor-llama/         NEW — Capacitor plugin: llama.cpp on iOS+Android
├── dvai-bridge-capacitor-foundation/    NEW — Capacitor plugin: Apple Foundation Models (iOS)
└── dvai-bridge-capacitor-mediapipe/     NEW — Capacitor plugin: MediaPipe LLM (Android)
```

Five new published packages; one existing package modified.

## 5. JS shim — `@dvai-bridge/capacitor`

About 150 LOC of TypeScript. Public surface:

```ts
export type CapacitorBackend = "llama" | "foundation" | "mediapipe";

export interface StartOptions {
  backend: CapacitorBackend;
  modelPath?: string;
  mmprojPath?: string;
  gpuLayers?: number;
  contextSize?: number;
  threads?: number;
  embeddingMode?: boolean;
  httpBasePort?: number;        // default 38883
  httpMaxPortAttempts?: number; // default 16
  corsOrigin?: string | string[];
  autoUnloadOnLowMemory?: boolean;
  logLevel?: "silent" | "info" | "debug";
}

export interface StartResult {
  baseUrl: string;
  port: number;
  backend: CapacitorBackend;
  modelId: string;
}

export interface ProgressEvent {
  phase: "loading" | "ready" | "error";
  bytesReceived?: number;
  bytesTotal?: number;
  percent?: number;
  message?: string;
}

export interface DownloadOptions {
  url: string;
  sha256: string;
  destFilename?: string;
  headers?: Record<string, string>;  // for HuggingFace gated repos, etc.
  onProgress?: (e: ProgressEvent) => void;
}

export interface CachedModelInfo {
  filename: string;
  path: string;
  bytes: number;
  sha256: string;
}

export const DVAIBridge = {
  start(opts: StartOptions): Promise<StartResult>,
  stop(): Promise<void>,
  status(): Promise<{ running: boolean; backend?: CapacitorBackend; baseUrl?: string }>,
  addProgressListener(cb: (e: ProgressEvent) => void): { remove: () => void },

  downloadModel(opts: DownloadOptions): Promise<{ path: string; cached: boolean }>,
  listCachedModels(): Promise<CachedModelInfo[]>,
  deleteCachedModel(filename: string): Promise<void>,
  cacheDir(): Promise<string>,
};
```

Internal dispatch:

```ts
import { registerPlugin } from "@capacitor/core";

const NATIVE_PLUGIN_BY_BACKEND = {
  llama:      () => registerPlugin<NativePluginInterface>("DVAIBridgeLlama"),
  foundation: () => registerPlugin<NativePluginInterface>("DVAIBridgeFoundation"),
  mediapipe:  () => registerPlugin<NativePluginInterface>("DVAIBridgeMediaPipe"),
};

let activePlugin: NativePluginInterface | null = null;
let activeBackend: CapacitorBackend | null = null;

async function start(opts: StartOptions): Promise<StartResult> {
  const native = NATIVE_PLUGIN_BY_BACKEND[opts.backend]();
  try {
    const result = await native.start(opts);
    activePlugin = native;
    activeBackend = opts.backend;
    return result;
  } catch (err) {
    if (isPluginNotImplementedError(err)) {
      throw new Error(
        `[DVAI] Backend "${opts.backend}" selected but the corresponding plugin ` +
        `is not installed. Run: npm install @dvai-bridge/capacitor-${opts.backend} && npx cap sync`
      );
    }
    throw err;
  }
}
```

If `@dvai-bridge/capacitor-${backend}` isn't installed, `native.start()` rejects with Capacitor's standard "plugin not implemented" error; the shim wraps it with an actionable message.

## 6. Core integration — new `"capacitor"` transport

`@dvai-bridge/core`'s `selectTransport()` (Phase 0) gains a fourth branch:

```ts
function selectTransport(input): "msw" | "http" | "none" | "capacitor" {
  if (input.serviceWorkerUrl === "" && input.transport == null) return "none";
  const requested = input.transport ?? "auto";
  if (requested !== "auto") return requested;

  if (isCapacitorContext()) return "capacitor";
  if (isBrowserLike())      return "msw";
  if (isNode())             return "http";
  return "none";
}

function isCapacitorContext(): boolean {
  return (
    typeof window !== "undefined" &&
    !!(window as any).Capacitor?.isNativePlatform?.()
  );
}
```

`CapacitorTransport` implements the same `Transport` interface as `MswTransport` and `HttpTransport`:

```ts
export class CapacitorTransport implements Transport {
  readonly kind = "capacitor" as const;
  constructor(private readonly opts: CapacitorTransportOptions) {}

  async start(_ctx: HandlerContext): Promise<TransportStartResult> {
    const { DVAIBridge } = await import("@dvai-bridge/capacitor");
    const result = await DVAIBridge.start({
      backend: this.opts.capacitorBackend ?? "llama",
      modelPath: this.opts.nativeModelPath,
      mmprojPath: this.opts.nativeMmprojPath,
      gpuLayers: this.opts.nativeGpuLayers,
      contextSize: this.opts.nativeContextSize,
      threads: this.opts.nativeThreads,
      embeddingMode: this.opts.nativeEmbeddingMode,
      httpBasePort: this.opts.httpBasePort,
      httpMaxPortAttempts: this.opts.httpMaxPortAttempts,
      corsOrigin: this.opts.corsOrigin,
    });
    return { baseUrl: result.baseUrl, port: result.port };
  }

  async stop(): Promise<void> {
    const { DVAIBridge } = await import("@dvai-bridge/capacitor");
    await DVAIBridge.stop();
  }
}
```

`HandlerContext` is unused — handlers run natively, not in JS.

### 6.1 New `DVAIConfig` fields

```ts
export interface DVAIConfig {
  // ...existing fields...
  capacitorBackend?: "llama" | "foundation" | "mediapipe";  // default "llama"
  nativeMmprojPath?: string;
}
```

### 6.2 Deletions

- `packages/dvai-bridge-core/src/NativeBackend.ts` — fully removed.
- `peerDependencies."llama-cpp-capacitor"` from `packages/dvai-bridge-core/package.json` — removed.
- `backend: "native"` branch in `DVAI.initializeBackend()` — removed.
- `backend` config field's valid values shrink to `"webllm" | "transformers" | "auto"`.
- All references in docs (`docs/guide/native-backend.md`, README config table) — replaced with new Capacitor docs.

No backward-compat shims. The library hasn't shipped to the public; clean rewrite.

## 7. Native plugin internals

### 7.1 Per-platform HTTP server libraries

- **iOS — Telegraph** (Swift, MIT, actively maintained). Pure Swift, supports SSE, ~120 KB. Vendored via SPM.
- **Android — Ktor with CIO engine** (Apache 2.0, JetBrains-maintained). Kotlin-native, coroutines, SSE built-in. Vendored via Gradle.

Both bind only to `127.0.0.1` — never the local network.

### 7.2 Handler protocol — the contract per platform

**Swift:**

```swift
public protocol DVAIHandlers: Sendable {
    func handleChatCompletion(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse
    func handleCompletion(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse
    func handleEmbeddings(body: [String: Any], ctx: HandlerContext) async throws -> HandlerResponse
    func handleModels(ctx: HandlerContext) async throws -> HandlerResponse
}

public struct HandlerContext {
    public let modelId: String
    public let backendName: String
}

public enum HandlerResponse {
    case json(Int, Any)
    case sse(AsyncStream<String>)
    case error(Int, String)
}
```

**Kotlin:**

```kotlin
interface DvaiHandlers {
    suspend fun handleChatCompletion(body: JsonObject, ctx: HandlerContext): HandlerResponse
    suspend fun handleCompletion(body: JsonObject, ctx: HandlerContext): HandlerResponse
    suspend fun handleEmbeddings(body: JsonObject, ctx: HandlerContext): HandlerResponse
    suspend fun handleModels(ctx: HandlerContext): HandlerResponse
}

data class HandlerContext(val modelId: String, val backendName: String)

sealed class HandlerResponse {
    data class Json(val status: Int, val body: JsonElement) : HandlerResponse()
    data class Sse(val flow: Flow<String>) : HandlerResponse()
    data class Error(val status: Int, val message: String) : HandlerResponse()
}
```

These mirror the Phase 0 TS handler signatures.

### 7.3 Per-plugin native code structure

Same skeleton across all three plugins:

```
packages/dvai-bridge-capacitor-llama/
├── package.json
├── src/index.ts              (~30 LOC, Capacitor plugin registration)
├── ios/
│   ├── Plugin.swift          (Capacitor plugin entry)
│   ├── HttpServer.swift      (Telegraph wrapper + port fallback)
│   ├── HandlerDispatch.swift (route dispatch)
│   ├── Handlers.swift        (LlamaHandlers — backend-specific)
│   ├── ContentPartsTranslator.swift
│   ├── AudioDecoder.swift    (AVAudioFile + AVAudioConverter)
│   ├── ImageDecoder.swift
│   ├── LlamaCppBridge.{h,mm} (ObjC++ wrapping llama.cpp C API)
│   └── llama.cpp/            (git submodule, pinned SHA)
└── android/
    ├── src/main/java/co/deepvoiceai/dvaibridge/llama/
    │   ├── Plugin.kt
    │   ├── HttpServer.kt
    │   ├── HandlerDispatch.kt
    │   ├── Handlers.kt
    │   ├── ContentPartsTranslator.kt
    │   ├── AudioDecoder.kt   (MediaExtractor + MediaCodec)
    │   └── ImageDecoder.kt
    ├── src/main/cpp/
    │   ├── jni-bridge.cpp
    │   └── CMakeLists.txt
    └── llama.cpp/            (git submodule, pinned SHA)
```

`capacitor-foundation` and `capacitor-mediapipe` mirror this layout, swapping the backend-specific files (no llama.cpp submodule for them; backend bridge files are different).

### 7.4 `capacitor-llama` — llama.cpp specifics

llama.cpp consumed as a git submodule pinned to a specific upstream SHA. We bump the SHA deliberately, with regression-test pass requirement; never auto-track main.

- **iOS:** custom CMakeLists.txt builds llama.cpp as a static library with Metal backend. Linked into the plugin via SPM's `cSettings`/`cxxSettings`. Supports iPhone 13+ (Metal 3).
- **Android:** standard Android NDK build via `externalNativeBuild` in Gradle. Builds for `arm64-v8a` (primary), `armeabi-v7a`, `x86_64` (emulator). Vulkan backend on arm64; CPU on others.

The Swift / Kotlin handlers translate OpenAI content parts → llama.cpp's API:
- Text → prompt construction with model-appropriate chat template
- Image → `mtmd_helper_eval` with mmproj (if loaded)
- Audio (PCM) → `mtmd_helper_eval_audio` (or current upstream equivalent) for native-audio-encoder models
- Audio (mp3/wav/m4a/aac/etc.) → platform-native decode → PCM → above

Streaming via llama.cpp's token-callback API, wrapped as `AsyncStream<String>` (Swift) / `Flow<String>` (Kotlin).

### 7.5 `capacitor-foundation` — Apple Foundation Models (iOS only)

iOS exclusive. Uses Apple's `LanguageModelSession`. Smallest plugin (~250 LOC of Swift).

**Version targeting:** the SwiftPM/CocoaPods package keeps `.iOS("18.1")` as the **link-time floor** so apps with an 18.1+ deployment target can still install and link `capacitor-foundation`. The FoundationModels public API (`LanguageModelSession`, etc.) is marked `@available(iOS 26.0, *)` in the shipped Xcode 26.4 SDK, so actually invoking the backend is gated at runtime on iOS 26.0+. On 18.1–25.x devices, `start()` rejects with a clear error; the handler class itself is annotated `@available(iOS 26, *)`.

- No model files (Apple curates).
- No GPU config, no quantization.
- No multimodal in Phase 1's API surface.
- No embedding API.
- Streaming via Apple's `responseStream` API.

Android side: returns clear `400 — Foundation Models is iOS-only. Use capacitorBackend: "mediapipe" or "llama" on Android.`

### 7.6 `capacitor-mediapipe` — Google MediaPipe LLM (Android only)

Uses Google's `com.google.mediapipe:tasks-genai` Gradle artifact. Models in MediaPipe `.task` format.

- Streaming via the SDK's listener API, adapted to coroutine `Flow<String>`.
- Multimodal: vision-capable Gemma tasks via `addImage(MPImage)`. No audio in Phase 1 (no audio-capable task variants yet).
- No embedding API.

iOS side: returns clear `400 — MediaPipe LLM is Android-only. Use capacitorBackend: "foundation" or "llama" on iOS.`

### 7.7 Port fallback (per platform)

Same `BASE_PORT = 38883`, `MAX_PORT_ATTEMPTS = 16` policy as Phase 0. Each platform implements a `tryBind` equivalent with EADDRINUSE retry. Throws an actionable error listing the tried range if all attempts fail.

### 7.8 CORS + Private Network Access

Identical headers to Phase 0's HTTP transport, on every response (incl. SSE):

```
Access-Control-Allow-Origin: *                  (configurable)
Access-Control-Allow-Methods: POST, GET, OPTIONS
Access-Control-Allow-Headers: Content-Type, Authorization
Access-Control-Allow-Private-Network: true
```

`OPTIONS *` returns 204 with the same headers, no body.

## 8. Multimodal pass-through

### 8.1 OpenAI content parts accepted

```ts
type ContentPart =
  | { type: "text"; text: string }
  | { type: "image_url"; image_url: { url: string; detail?: "low" | "high" | "auto" } }
  | { type: "input_audio"; input_audio: { data: string; format: "mp3" | "wav" | "m4a" | "aac" | "pcm16" } }
```

### 8.2 Image translation

`image_url.url` parses three forms: `data:image/...;base64,...`, `https://...`, and `file://...`. The plugin decodes / fetches → encoded image bytes (PNG/JPEG/etc.) → backend's image-input call:

- llama.cpp: `mtmd_helper_eval` with loaded mmproj (decodes PNG/JPEG internally).
- Foundation Models: 400 (not in current API surface).
- MediaPipe LLM: `addImage(MPImage)` for vision-capable models.

### 8.3 Audio translation

Plugin accepts mp3 / wav / m4a / aac / pcm16. Decodes to raw PCM via platform-native APIs:

- iOS: `AVAudioFile` + `AVAudioConverter`. Built-in. Supports mp3, wav, m4a, aac, flac.
- Android: `MediaExtractor` + `MediaCodec`. Built-in. Supports mp3, wav, m4a, aac, ogg.
- pcm16: skip decoding; passthrough.

PCM samples handed to the backend's audio API:

- llama.cpp (Gemma 4, Phi-4 multimodal, etc.): `mtmd_helper_eval_audio` (or current upstream equivalent).
- Foundation Models: 400 (not in current API).
- MediaPipe LLM: 400 (no audio-capable tasks in Phase 1).

Format-availability table (per OS):

| Format | iOS | Android |
|---|---|---|
| pcm16 | ✅ direct | ✅ direct |
| wav | ✅ | ✅ |
| mp3 | ✅ | ✅ |
| m4a / aac | ✅ | ✅ |
| flac | ✅ | ❌ → 400 |
| ogg | ❌ → 400 | ✅ |

Documented per-platform.

### 8.4 Per-backend modality matrix

| Modality | `capacitor-llama` | `capacitor-foundation` | `capacitor-mediapipe` |
|---|---|---|---|
| Text | ✅ | ✅ | ✅ |
| Image | ✅ if mmproj loaded | ❌ | ✅ if vision-capable model |
| Audio | ✅ if model has native audio encoder | ❌ | ❌ |
| Streaming SSE | ✅ | ✅ | ✅ |
| Embeddings | ✅ if `embeddingMode: true` | ❌ | ❌ |

### 8.5 Error responses

| Situation | Status | Body |
|---|---|---|
| Image content part on llama, no mmproj loaded | 400 | `{ error: "Request includes an image but no mmproj was loaded. Set nativeMmprojPath when starting." }` |
| Image content part on foundation | 400 | `{ error: "Image input not supported by Apple Foundation Models in this version." }` |
| Audio content part, model without audio encoder | 400 | `{ error: "Loaded model has no native audio encoder. Use a multimodal model like Gemma 4 or Phi-4 Multimodal." }` |
| Image fetch from `https://` URL fails | 502 | `{ error: "Failed to fetch image: <reason>" }` |
| Audio decode fails | 400 | `{ error: "Audio decode failed: <reason>" }` |
| Unsupported audio format | 400 | `{ error: "Unsupported audio format: <fmt>. Supported on this platform: <list>." }` |

### 8.6 Translator code organization

Each plugin gets a `ContentPartsTranslator` (Swift class / Kotlin object), ~200-300 LOC. The handlers are kept dumb — parse JSON, call translator, call backend, format response.

## 9. Model distribution

### 9.1 The contract

Every backend plugin's `start()` accepts an optional `modelPath`. The plugin runs whatever's at that path. How the file got there is the developer's call.

Exception: `capacitor-foundation` doesn't take `modelPath` — Apple manages the model.

### 9.2 The optional `downloadModel()` helper

Available on `@dvai-bridge/capacitor`:

```ts
DVAIBridge.downloadModel({
  url: string,
  sha256: string,                     // required
  destFilename?: string,              // defaults to URL basename
  headers?: Record<string, string>,   // for HuggingFace gated repos
  onProgress?: (e: ProgressEvent) => void,
}): Promise<{ path: string; cached: boolean }>
```

Steps:

1. Compute destination path:
   - iOS: `<App Support>/<bundle-id>/dvai-models/<destFilename>`
   - Android: `<filesDir>/dvai-models/<destFilename>`
2. If file exists with matching sha256: return `{ path, cached: true }`.
3. If file exists with mismatched sha256: delete, fall through to download.
4. Resumable HTTP Range download into `<destFilename>.partial`, computing sha256 incrementally.
5. Verify final sha256 matches expected. Mismatch → delete partial + destination, throw `ChecksumMismatchError`.
6. Atomic rename `.partial` → final destination.
7. iOS only: set `URLResourceKey.isExcludedFromBackupKey = true` on the file.

`onProgress` events debounced to ~10/sec.

### 9.3 Cache management API

```ts
DVAIBridge.listCachedModels(): Promise<CachedModelInfo[]>
DVAIBridge.deleteCachedModel(filename: string): Promise<void>
DVAIBridge.cacheDir(): Promise<string>
```

Three methods. No auto-eviction. No max-size enforcement. Developer policy.

### 9.4 What gets documented post-implementation

`docs/guide/model-distribution.md` covers:

1. Where to host models (HF LFS, S3, custom CDN — pros/cons).
2. How to compute sha256 (`shasum -a 256` / `Get-FileHash`).
3. First-run UX patterns (download progress UI; cancel; resume).
4. Bundling small models in `public/`.
5. Multi-file models (GGUF + mmproj download as a pair).
6. Auth for gated HF repos.
7. Disk-space pre-checks via Capacitor's Filesystem plugin.
8. Privacy posture for hosted models.

## 10. Operational concerns

### 10.1 Lifecycle

The HTTP server lives only as long as the app process foreground lifecycle. No background-execution privileges requested. Documented behavior: requests in flight when the app backgrounds may fail; server resumes when app foregrounds.

### 10.2 Memory pressure

`autoUnloadOnLowMemory: boolean` flag on `start()`. Default `false`. When `true`:
- iOS: subscribes to `UIApplication.didReceiveMemoryWarningNotification`.
- Android: `ComponentCallbacks2.onTrimMemory(level)` at TRIM_MEMORY_RUNNING_CRITICAL or higher.
On warning, plugin calls its own `stop()` and emits a progress event so the JS layer can respond.

Native bridges allocate large buffers via `mmap`, allowing the OS to reclaim pages.

### 10.3 NSC injection (Android cleartext-to-loopback)

Plugin Gradle scripts inject a `network_security_config.xml` allowlisting cleartext for `127.0.0.1` and `localhost` only, via Android manifest merging. Developer doesn't touch their config.

If host app already has its own NSC with conflicting rules, the merger's `tools:replace` directive wins. Documented in setup guide for explicit-override cases.

### 10.4 iOS ATS

ATS exempts loopback by default. No `Info.plist` changes needed. Documented as "iOS: nothing to configure."

### 10.5 Observability — native logs

iOS: `OSLog` with subsystem `co.deepvoiceai.dvai.bridge`, categories `lifecycle` / `http` / `inference`.
Android: `Log.d/i/w/e` with tag `DVAIBridge`.
Verbose level toggled by `logLevel: "silent" | "info" | "debug"` on `start()`.

The `GET /_debug/recent-requests` endpoint is deferred (Phase 0 deferral, applies here too — single coordinated debug surface near launch).

### 10.6 Crash safety

llama.cpp can crash on malformed inputs. Defenses:
- Validate request JSON shape in the dispatch layer; bad shapes → 400.
- Bridge wraps llama.cpp calls with return-code checks.
- Pre-flight memory-budget heuristic: if estimated tensor RAM exceeds available device RAM, return 503 before calling llama.cpp.
- Some C++ assertion failures can't be caught — documented as developer responsibility ("untrusted inputs to local LLM inference").

## 11. Testing strategy

### 11.1 Test layers

| Layer | Tests | Where | Cadence |
|---|---|---|---|
| TS unit + handler equivalence | TS handlers + selectTransport branches incl. new "capacitor" | vitest, ubuntu-latest | Every PR |
| Swift unit + handler equivalence | Swift handlers vs shared fixtures | xcodebuild, iOS Simulator | Every PR |
| Kotlin unit + handler equivalence | Kotlin handlers vs shared fixtures | Gradle JVM tests | Every PR |
| Audio decoder tests | Format → PCM correctness | XCTest / Android instrumented | Per-PR if related paths change |
| Real-model smoke tests | Real GGUF, real inference | Self-hosted iOS sim + Android emulator | Nightly + pre-release |

### 11.2 Shared fixtures — `fixtures/transport-fixtures.json`

Single language-neutral source of truth. Phase 0's `transport-fixtures.ts` refactors: JSON content extracted to `fixtures/transport-fixtures.json` at repo root; the TS file becomes a thin loader. Swift and Kotlin tests load the same JSON. Includes:

- Text request/response pairs (Phase 0 baseline)
- Multimodal request fixtures: image (data URL), audio (pcm16, mp3, wav)
- Canned response shapes for mock backends

Plus `fixtures/audio/*` and `fixtures/images/*` for binary content (~5 small files, total < 200 KB).

### 11.3 Per-platform test infrastructure

- **Swift:** XCTest target per backend plugin. `MockLlamaBridge` (etc.) returns canned responses. `xcodebuild test -destination 'platform=iOS Simulator,name=iPhone 15'`.
- **Kotlin:** JUnit 5 + kotlinx-coroutines-test + Robolectric (minimal usage). JVM tests in `src/test/`. Audio-decoder tests requiring `MediaCodec` go in `src/androidTest/` (instrumented, run on emulator).

### 11.4 CI matrix — GitHub Actions

| Job | Runner | Cost |
|---|---|---|
| `test-typescript` | ubuntu-latest | ~3-5 min |
| `test-ios-llama` | self-hosted macOS | ~5-8 min |
| `test-ios-foundation` | self-hosted macOS | ~3-5 min |
| `test-android-llama-jvm` | ubuntu-latest | ~3-4 min |
| `test-android-mediapipe-jvm` | ubuntu-latest | ~2-3 min |
| `test-android-instrumented` | self-hosted macOS or ubuntu | ~10-15 min, conditional via paths-filter |
| `fixtures-lint` | ubuntu-latest | ~30 sec |
| `build-llama-submodule` | matrix (both) | ~10-20 min, conditional on submodule SHA change |

### 11.5 Active development-time testing discipline (not just CI)

CI gates merges; the inner loop is what catches bugs while implementation is happening. The volume of native code in Phase 1 (Swift, Kotlin, ObjC++, JNI, two HTTP server libraries, three SDK integrations) means we cannot defer verification to "after everything is written." Each unit gets exercised against its tests before moving on.

**Concrete discipline during Phase 1 implementation:**

- After each Swift / ObjC++ source file is written or modified — run the relevant XCTest target via `pnpm --filter @dvai-bridge/capacitor-llama mac:test` (SSH to Mac, build, test, results stream back). Don't accumulate untested Swift changes.
- After each Kotlin / JNI source file is written or modified — run the relevant Gradle test task locally (Android Studio + Windows-side Android emulator, no Mac dependency for Android side).
- After every fixture file change — re-run the parity test on all three platforms (TS / Swift / Kotlin) before considering the change complete.
- After audio decoder changes — run instrumented tests on the Android emulator AND iOS Simulator. Don't skip the emulator-required tier just because it's slower.
- After any handler change — run all three platforms' handler-equivalence tests. Drift gets caught at the moment it's introduced, not at PR time.
- TDD pattern from Phase 0 carries over: write the failing test, see it fail, write the implementation, see it pass, commit. Cycle per native file, not per native module.

The implementation plan (next step after this spec) breaks every native file's introduction into "write test → run test (see fail) → write implementation → run test (see pass) → commit" steps. The agent executing the plan runs the relevant test suite at every step, not at the end.

**Why this matters more in Phase 1 than Phase 0:**

- Native code can fail in many more ways than TypeScript: linker errors, ABI mismatches, NDK toolchain issues, ObjC++ name-mangling, JNI signature mismatches, llama.cpp ABI changes between submodule SHAs.
- Iteration cost is higher (CI cycle, simulator boot, emulator boot) — better to catch issues immediately at the unit level than after multiple changes pile up.
- Cross-language parity drift is silent — only the test catches it.

CI in §11.4 / §11.6 is the long-term safety net. Active test-runs during implementation are the short-term safety net. Both ship.

### 11.6 Self-hosted runner on the developer's MacBook

CI for iOS jobs runs on the developer's MacBook (already SSH-set-up). Configuration steps go in `docs/development/mac-remote-builds.md`. Workflow YAML uses generic labels `[self-hosted, macOS, ARM64]` — no machine-specific identifiers committed to the repo.

**Privacy hardening:**
- Mac-side configuration (SSH alias, repo path, username) lives in a gitignored local file: `scripts/mac.local.json`.
- `.gitignore` entries: `scripts/mac.local.json`, `scripts/*.local.json`, `.env.local`.
- `mac-build.ps1` reads from local file or `DVAI_MAC_*` environment variables.
- Workflow YAML never references hostname / IP / username.
- Self-hosted runner registration token is single-use (~1 hour TTL).

### 11.7 Smart test invocation (CI gating only)

Note: this section governs **CI behavior** only. Section 11.5 governs developer-time test runs, which are not gated — every related test runs on every change during implementation.



GitHub Actions `paths-filter` (via `dorny/paths-filter@v3` or equivalent) gates expensive jobs by changed-file paths:

| Job | Triggered when changes touch |
|---|---|
| Audio decoder instrumented (Android) | `android/.../audio-decoder/**`, `androidTest/AudioDecoder*`, `fixtures/audio/**` |
| Audio decoder XCTest (iOS) | `ios/.../AudioDecoder*`, `fixtures/audio/**` |
| Handler equivalence (TS, Swift, Kotlin all) | `handlers/**`, `fixtures/transport-fixtures.json` |
| Port fallback | `port-fallback*`, `transports/http*`, `HttpServer*` |
| llama.cpp build verification | submodule SHA, CMakeLists.txt, NDK build files |
| Real-model smoke | Any `cpp/`, `Swift`, `Kotlin` change in `capacitor-llama` |

### 11.8 Real-model smoke tests — separate slow tier

`.github/workflows/smoke-real-models.yml` runs nightly + on `workflow_dispatch`. Uses Tier 1 development models (see § 11.9). Tier 2 pre-release models run manually on real devices before tagging a release.

What gets verified:
- Model loads on real (simulated) device
- HTTP server serves OpenAI requests
- Streaming SSE works
- Memory unload-reload cycle
- Multimodal: 1 image request, 1 audio request

What's deliberately NOT verified: output quality, specific token counts, latency. Mechanics only.

### 11.9 Test models

The current authoritative list lives in `docs/guide/tested-models.md`. The spec lists representative entries for context:

**Tier 1 — development / per-PR smoke (cached on self-hosted runner):**

| Purpose | Model | Quant | Size |
|---|---|---|---|
| Text completion | Llama-3.2-1B-Instruct | Q4_K_M | ~770 MB |
| Embeddings | bge-small-en-v1.5 | Q8_0 GGUF | ~133 MB |
| Multimodal | gemma-4-E2B-it | Q4_0 + mmproj | ~1.5 GB |

**Tier 2 — pre-release (manual, full coverage):**

| Purpose | Model | Quant | Size |
|---|---|---|---|
| Multimodal flagship | gemma-4-E4B-it | Q4_K_M + mmproj | ~3.5 GB |
| Multimodal alternative | Qwen3.5-VL (built-in vision encoder) | Q4_K_M | ~1.7 GB |
| Long context | Llama-3.2-3B-Instruct | Q4_K_M | ~2 GB |
| Multilingual / extra modality | Phi-4-multimodal-instruct | Q4_K_M | ~7 GB |

**Tier 3 — Apple FM / MediaPipe specific:**

| Purpose | Notes |
|---|---|
| Apple FM smoke | Apple's curated 3B (auto-loaded). Real device required (sim limited). |
| MediaPipe LLM smoke | Gemma-2B-it `.task` format from Google's `tasks-genai` artifact. |

Model files are not committed to git. Cached on self-hosted runner; CI verifies checksums against a config file in git.

## 12. Documentation deliverables

Created or rewritten as part of Phase 1:

- `docs/guide/quickstart-capacitor.md` — start-to-finish integration guide.
- `docs/guide/native-backend.md` — full rewrite (was `llama-cpp-capacitor`-specific).
- `docs/guide/model-distribution.md` — per § 9.4.
- `docs/guide/multimodal.md` — content-parts format, per-backend support, error semantics.
- `docs/guide/tested-models.md` — current authoritative model list.
- `docs/development/testing.md` — full test-running guide (TS, Swift, Kotlin, smoke).
- `docs/development/mac-remote-builds.md` — SSH-to-Mac setup, generic placeholders.
- `docs/development/handler-parity.md` — discipline rule for cross-language handler changes.
- README.md — Capacitor section updated to reflect new package set.
- POSITIONING.md — capacitor-foundation / capacitor-mediapipe added to plugin family.

## 13. Out-of-band development environment

Phase 1 development can happen primarily from the developer's Windows machine, with iOS builds running on a self-hosted MacBook over SSH. Setup documented; scripts authored as part of the implementation plan; no Mac-specific identifiers committed to the repo.

Real-device iOS / Android validation deferred to manual pre-release runs.

## 14. Open questions / confirmation items

1. **Phase 1 → Phase 2 sequencing.** Phase 2 (Electron NAPI) builds on the same llama.cpp pinned-submodule + first-party-bindings infrastructure that Phase 1 introduces. Phase 1 spec deliberately puts the submodule + CMake pattern in `capacitor-llama` first; Phase 2 reuses or refactors. No decision needed in Phase 1; flagged for Phase 2 spec.

2. **Tier 2 model list ownership.** The list in `docs/guide/tested-models.md` will need ongoing curation as the model landscape evolves. Phase 1 ships an initial set; future updates are docs-only changes (no spec amendments needed).

3. **Foundation Models multimodal.** Apple may add image/audio support to `LanguageModelSession` in a future iOS release. When that happens, `capacitor-foundation` extends without breaking — content parts that map to FM's new APIs simply start working. Forward-compatible; no spec change.

## 15. Deliverable summary

A single PR set (likely several stacked PRs under one branch) containing:

1. Four new packages: `@dvai-bridge/capacitor`, `@dvai-bridge/capacitor-llama`, `@dvai-bridge/capacitor-foundation`, `@dvai-bridge/capacitor-mediapipe`. Plus updates to existing `@dvai-bridge/core`.
2. Native plugin code: Swift + ObjC++ for iOS, Kotlin + JNI for Android.
3. Multimodal pass-through translators with platform-native audio decoders.
4. `downloadModel()` helper with resumable + checksum verification.
5. Shared fixture file extracted from Phase 0; Swift and Kotlin loaders.
6. Test suites in three languages, parity-enforced via shared fixtures.
7. Self-hosted CI runner setup (developer's Mac, no machine details in repo).
8. Mac-remote-build helper scripts (gitignored config, env-var driven).
9. Documentation: 8 new / rewritten guides + README & POSITIONING updates.
10. `NativeBackend.ts` deletion + `llama-cpp-capacitor` peer-dep removal.

All existing Phase 0 tests continue to pass. No breaking changes to the published web/Node path. Capacitor consumers see a clean rewrite — acceptable per "no published Capacitor users yet" decision.
