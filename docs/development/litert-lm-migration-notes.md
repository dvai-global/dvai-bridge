# LiteRT-LM Migration Notes

> **Status:** Research complete — LiteRT-LM is **stable** (latest: `0.10.2`, Apr 17 2026).
> This document is the Phase 3B inventory artifact (Task 16).
> It is consumed by Tasks 17 (interface neutralization), 19 (build.gradle swap), 20 (bridge rewrite), and 21 (test parity).

---

## 1. Artifact Coordinates

### Primary artifact (replaces `tasks-genai`)

| Role | Coordinate |
|---|---|
| Android runtime | `com.google.ai.edge.litertlm:litertlm-android:0.10.2` |
| JVM runtime (tests) | `com.google.ai.edge.litertlm:litertlm-jvm:0.10.2` |

Use `latest.release` in place of an explicit version if you want automatic tracking, but pin to `0.10.2` (or newer) for reproducible builds:

```gradle
implementation("com.google.ai.edge.litertlm:litertlm-android:0.10.2")
```

The package is hosted on **Google Maven** (not Maven Central). No separate `litert-core` or `litert-tasks-core` companion artifact is required — `litertlm-android` bundles the full runtime.

**GPU backend** additionally requires two native library declarations in `AndroidManifest.xml`:

```xml
<application>
  <uses-native-library android:name="libvndksupport.so" android:required="false"/>
  <uses-native-library android:name="libOpenCL.so" android:required="false"/>
</application>
```

**Release cadence:** stable releases since `0.9.0` (Mar 27 2026). The earlier `0.9.0-alpha01` through `0.9.0-beta` were pre-release. The Kotlin API is marked **Stable** on the GitHub repo.

Sources: [1] [2] [3]

---

## 2. Class Mappings

| Old (`tasks-genai`) | New (`litertlm-android`) | Notes |
|---|---|---|
| `LlmInference` | `Engine` | Entry-point class. Constructed with `EngineConfig`; must call `engine.initialize()` before use. |
| `LlmInference.LlmInferenceOptions` (Builder) | `EngineConfig` (data class / named params) | No builder pattern — Kotlin named-argument constructor. |
| `LlmInferenceSession` | `Conversation` | Per-request (or multi-turn) interaction unit. Created via `engine.createConversation(config?)`. |
| `LlmInferenceSession.LlmInferenceSessionOptions` (Builder) | `ConversationConfig` (data class / named params) | No builder pattern. |
| `GraphOptions` (incl. `setEnableVisionModality(true)`) | `EngineConfig.visionBackend: Backend?` | Vision is enabled at the engine level by passing a `visionBackend` (e.g. `Backend.GPU()`) in `EngineConfig`. No per-session flag needed. |
| `MPImage` (image input type) | `Content.ImageBytes(byteArray: ByteArray)` or `Content.ImageFile(path: String)` | No `MPImage` wrapper. Raw `ByteArray` or file path. See Section 4 for format details. |
| `LlmInference.Backend` (enum: `GPU`, `CPU`) | `Backend` (sealed class: `Backend.CPU()`, `Backend.GPU()`, `Backend.NPU(nativeLibraryDir)`) | Sealed class replaces enum; GPU and NPU gain separate `visionBackend` / `audioBackend` slots. |

Import change: `import com.google.ai.edge.litertlm.*`

---

## 3. Method Mappings

### Engine / initialization

| Old | New | Notes |
|---|---|---|
| `LlmInference.createFromOptions(context, opts): LlmInference` | `Engine(engineConfig)` + `engine.initialize()` | Two-step. Constructor is cheap; `initialize()` is the heavy model-load (~10 s). Warm-up must be off the main thread. |
| `LlmInferenceOptions.Builder.setModelPath(path)` | `EngineConfig(modelPath = path, ...)` | Named parameter in constructor. |
| `setPreferredBackend(Backend.GPU)` | `EngineConfig(backend = Backend.GPU())` | `Backend` is now a sealed class, not an enum. |
| `setMaxNumImages(int)` | `EngineConfig(visionBackend = Backend.GPU())` | There is no numeric image-count cap in the public API. Vision is gated by whether `visionBackend` is set, not a max count. See Section 5 (Risk Register). |
| `setMaxTopK(int)` | No direct equivalent — **TBD / not yet found in public docs** | `setMaxTopK` is an engine-level cap on per-session topK. `LiteRT-LM` exposes per-conversation `SamplerConfig(topK = …)` only. No global cap found. See Section 5. |
| `setMaxTokens(int)` | `EngineConfig(kvCacheMaxTokens = int?)` (tentative) | The `EngineConfig` accepts optional KV-cache tuning; exact parameter name not confirmed in public docs. May default to model maximum. See Section 5. |

### Session / conversation

| Old | New | Notes |
|---|---|---|
| `LlmInferenceSession.createFromOptions(engine, sessionOpts)` | `engine.createConversation(conversationConfig?)` | `conversationConfig` is optional; pass `null` for defaults. |
| `setTopK(int)` | `ConversationConfig(samplerConfig = SamplerConfig(topK = int))` | Named arg inside `SamplerConfig` data class. |
| `setTemperature(float)` | `ConversationConfig(samplerConfig = SamplerConfig(temperature = float))` | Same. |
| `setGraphOptions(GraphOptions.builder().setEnableVisionModality(true).build())` | Removed — handled at engine level via `EngineConfig.visionBackend` | No per-session graph options concept. |

### Message sending

| Old | New | Notes |
|---|---|---|
| `session.addQueryChunk(prompt: String)` | `conversation.sendMessage(prompt)` or `conversation.sendMessageAsync(prompt)` | LiteRT-LM uses a single-call model — no separate "add chunk then generate" split. Text + images are bundled into one `sendMessage` call. |
| `session.addImage(image: MPImage)` | Include `Content.ImageBytes(byteArray)` in the `Contents.of(...)` passed to `sendMessage` | Images are co-sent with the text prompt in a single call. See Section 4 for `ByteArray` format. |
| `session.generateResponse(): String` | `conversation.sendMessage(contents): Message` (then read `.text`) | Blocking, returns a `Message`. Call `.text` on the result for the String. |
| `session.generateResponseAsync(progressListener: (partial, done) -> Unit)` | `conversation.sendMessageAsync(contents): Flow<Message>` (coroutines) OR `conversation.sendMessageAsync(contents, callback: MessageCallback)` (callback style) | Two overloads. `Flow<Message>` is preferred for Kotlin coroutine users. Callback interface has `onMessage(Message)`, `onDone()`, `onError(Throwable)`. |

---

## 4. Behavioral Deltas

### Model file format

`tasks-genai` consumed `.task` bundles. LiteRT-LM uses **`.litertlm`** files. These are distinct formats — existing `.task` models cannot be loaded by LiteRT-LM. Pre-converted `.litertlm` models are available from the [HuggingFace LiteRT Community](https://huggingface.co/litert-community). [4]

### Streaming API

`tasks-genai` used a single `ProgressListener<String>` callback (`(partial, done) -> Unit`). LiteRT-LM offers **two overloads**:

1. `sendMessageAsync(contents): Flow<Message>` — Kotlin coroutines / Flow (recommended)
2. `sendMessageAsync(contents, callback: MessageCallback)` — callback interface with `onMessage` / `onDone` / `onError`

The callback style maps 1:1 to what we currently do, but the Flow overload is the strategic Kotlin path. Either can be adopted; Task 20 should prefer `Flow` unless the existing `(partial, done) -> Unit` callback shape must be preserved for the `MediaPipeBridgeApi` interface contract.

### Vision / image input type

`tasks-genai` wrapped images in `MPImage` (a MediaPipe-specific type). LiteRT-LM removes this entirely. Images are passed as one of:

- `Content.ImageBytes(byteArray: ByteArray)` — in-memory, raw byte array
- `Content.ImageFile(path: String)` — absolute file path

The **expected byte format for `ImageBytes` is not explicitly documented** in the public API docs as of retrieval date. Based on the DeepWiki analysis, the bytes undergo Base64 encoding before reaching the native layer, implying any standard image format (JPEG, PNG) that the underlying C++ runtime accepts should work. Confirm by examining the `google-ai-edge/LiteRT-LM` source or running a smoke test. [5]

**Critical implication for Task 17 (interface neutralization):** The current plan neutralizes `List<MPImage>` → `List<ByteArray>`. That choice aligns with LiteRT-LM's `Content.ImageBytes(ByteArray)`. No change needed to the planned neutralization direction.

### Audio modality

LiteRT-LM ships **audio support** that `tasks-genai` never had. Multimodal audio is enabled by setting `EngineConfig.audioBackend` and passing `Content.AudioBytes(byteArray)` or `Content.AudioFile(path)` alongside text. Our current bridge does not use audio — no migration risk, but it is new capability available post-migration.

### Initialization & Context

`tasks-genai` passed `Android Context` directly to `LlmInference.createFromOptions(context, opts)`. LiteRT-LM does **not** accept `Context` in `EngineConfig` or `Engine(...)`. Context is only needed for deriving paths:

- `cacheDir = context.cacheDir.path` (optional; improves 2nd-load time)
- `nativeLibraryDir = context.applicationInfo.nativeLibraryDir` (NPU only)

These are plain `String` paths. **The `MediaPipeBridge` constructor signature can drop the `Context` parameter** (or keep it only for path derivation) — the bridge no longer needs to pass it deep into the SDK call.

### Conversation model vs. session model

`tasks-genai` creates a new `LlmInferenceSession` per request (stateless accumulation of chunks + images, then generate). LiteRT-LM's `Conversation` is **stateful and multi-turn** — it retains message history. For a stateless request pattern (one prompt → one response, no history), create a fresh `Conversation` per request via `engine.createConversation()` and close it after. This matches our current per-session pattern.

### `setMaxTopK` replacement

In `tasks-genai`, `setMaxTopK(int)` on the engine options caps the per-session topK across all sessions. LiteRT-LM exposes only per-conversation `SamplerConfig.topK`. There is no engine-level maximum-topK guard in the public API. If this cap is needed for safety or resource control, it must be enforced in our wrapper layer (e.g., `min(requestedTopK, MAX_TOP_K)` before constructing `SamplerConfig`).

---

## 5. Risk Register

| Risk | Severity | Notes |
|---|---|---|
| **Model file format mismatch** (`.task` → `.litertlm`) | HIGH | All model files must be replaced or re-converted before running LiteRT-LM. No in-place compatibility. CI smoke tests using `.task` bundles will fail until models are swapped. |
| **`setMaxNumImages` has no equivalent** | MEDIUM | `tasks-genai` accepted a numeric image cap at the engine level. LiteRT-LM's `EngineConfig` has no `maxNumImages` parameter in its documented public surface. The cap may be model-dependent or may require a wrapper enforcement. Confirm by reading `EngineConfig` source. |
| **`setMaxTopK` has no engine-level equivalent** | MEDIUM | See Section 4. Must be enforced in our wrapper if the cap matters. |
| **`ImageBytes` byte format undocumented** | MEDIUM | The exact encoding expected by `Content.ImageBytes` is not stated. A wrong format will produce silent garbage or runtime errors. Needs a targeted smoke test (try JPEG bytes first). |
| **`setMaxTokens` / KV-cache cap** | LOW-MEDIUM | Our bridge passes `maxTokens: Int = 2048`. LiteRT-LM likely has an analogous KV-cache limit parameter but the exact name is not confirmed in public docs. Needs verification against `EngineConfig` constructor source or Javadoc. |
| **`Flow<Message>` vs. `(partial, done) -> Unit`** | LOW | The existing `MediaPipeBridgeApi` interface uses `(String, Boolean) -> Unit`. If the bridge rewrite adopts `Flow`, the interface must change. This is a planned interface change (Task 17 / 20) but must be coordinated so the Capacitor wrapper layer adapts. |
| **`Context` parameter removal** | LOW | `MediaPipeBridge` currently takes `Context` in its constructor. Post-migration, `Context` is only needed for optional path strings. The constructor signature change is a minor breaking API change for callers. |
| **GPU manifest entries** | LOW | GPU usage now requires `<uses-native-library>` entries in `AndroidManifest.xml`. Missing these causes silent CPU fallback or a runtime error. Must be added in Task 19 (build.gradle swap). |
| **Maven availability** | NONE | `litertlm-android:0.10.2` is a stable release on Google Maven. No availability risk. |

---

## 6. Recommended Migration Approach

### Decision: Pure 1:1 replacement with targeted interface adjustments

LiteRT-LM is stable and its API is a close conceptual match to `tasks-genai`. The recommended approach is a **direct replacement** — not a wrapper abstraction layer over both SDKs.

Rationale:
- `litertlm-android:0.10.2` is a production-stable release (not alpha/beta).
- The API delta is bounded: same conceptual entities (engine → conversation → message), different names and construction patterns.
- Keeping `tasks-genai` as a fallback would mean maintaining two code paths indefinitely, which conflicts with the project goal of eliminating the deprecated dependency.

### Task-by-task execution order

1. **Task 17 — Interface neutralization (already planned):** Change `MediaPipeBridgeApi` to accept `List<ByteArray>` instead of `List<MPImage>`. This is correct for LiteRT-LM (`Content.ImageBytes(ByteArray)`) and should proceed as planned. No change needed to the neutralization direction — `ByteArray` is exactly what LiteRT-LM wants.

2. **Task 19 — build.gradle swap:** Replace `com.google.mediapipe:tasks-genai:0.10.33` with `com.google.ai.edge.litertlm:litertlm-android:0.10.2`. Add `<uses-native-library>` manifest entries for GPU.

3. **Task 20 — Bridge rewrite:** Replace `MediaPipeBridge.kt` internals:
   - `LlmInference` → `Engine` + `engine.initialize()` (move to background thread or coroutine at construction)
   - `LlmInferenceSession` → `engine.createConversation()` per request (close after each)
   - `LlmInferenceOptions.builder()...` → `EngineConfig(modelPath, backend = Backend.GPU(), visionBackend = Backend.GPU())`
   - `LlmInferenceSessionOptions.builder()...` → `ConversationConfig(samplerConfig = SamplerConfig(topK, temperature))`
   - `session.addQueryChunk(prompt)` + `session.addImage(mpImage)` → build a `Contents.of(Content.ImageBytes(bytes), Content.Text(prompt))` list and pass to `sendMessage` / `sendMessageAsync` in one call
   - `session.generateResponse()` → `conversation.sendMessage(contents).text`
   - `session.generateResponseAsync { partial, done -> }` → either `conversation.sendMessageAsync(contents, MessageCallback)` (minimal delta) or `conversation.sendMessageAsync(contents).collect { }` (Flow, preferred)
   - Drop `@Suppress("DEPRECATION")` — LiteRT-LM is not deprecated.
   - Drop `import com.google.mediapipe.*` blocks; add `import com.google.ai.edge.litertlm.*`
   - Remove `Context` from engine construction call (keep in constructor only for optional cache path).

4. **Task 21 — Test parity:** Existing unit tests using the `MediaPipeBridgeApi` fake need no changes (the fake implements the neutralized interface). Integration tests referencing `.task` model files must be updated to use `.litertlm` files.

### On `ByteArray` image neutralization (Task 17 interaction)

The planned `List<MPImage>` → `List<ByteArray>` neutralization is **correct for LiteRT-LM**. Each `ByteArray` maps 1:1 to `Content.ImageBytes(byteArray)`. No further format wrapping (e.g. a `data class ImageInput(bytes: ByteArray, mimeType: String)`) is needed unless the `ImageBytes` smoke test reveals that the native layer requires a specific container format (e.g. JPEG-only). Hold Task 17 at `List<ByteArray>` and revisit only if the smoke test (Task 21) fails on image inputs.

---

## Sources

| # | URL | Retrieved |
|---|---|---|
| [1] | https://ai.google.dev/edge/litert-lm/android | 2026-04-26 |
| [2] | https://github.com/google-ai-edge/LiteRT-LM/blob/main/docs/api/kotlin/getting_started.md | 2026-04-26 |
| [3] | https://libraries.io/maven/com.google.ai.edge.litertlm:litertlm-android | 2026-04-26 |
| [4] | https://huggingface.co/litert-community | 2026-04-26 |
| [5] | https://deepwiki.com/google-ai-edge/LiteRT-LM/4.6-kotlin-and-android-api | 2026-04-26 |
| [6] | https://mvnrepository.com/artifact/com.google.ai.edge.litertlm/litertlm-android | 2026-04-26 |
| [7] | https://github.com/google-ai-edge/LiteRT-LM | 2026-04-26 |
| [8] | https://ai.google.dev/edge/litert-lm/overview | 2026-04-26 |
