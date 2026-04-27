# Phase 3D — Android Native SDK (`@dvai-bridge/android` / `co.deepvoiceai:dvai-bridge`)

**Status:** Draft — awaiting review
**Date:** 2026-04-27
**Scope:** New top-level Android SDK package that wraps the Phase 3A/3B core modules (`android-llama-core` + `android-mediapipe-core`) plus a new LiteRT backend, exposes the same OpenAI-compatible HTTP surface as the rest of the dvai-bridge family, and ships via Maven (GitHub Packages → eventual Maven Central) as an AAR.

**Sub-phase position in Phase 3:**

```
3A core extraction ✅ → 3B LiteRT-LM migration ✅ → 3C iOS SDK ✅
                                                  → 3D Android AAR ◀️ YOU ARE HERE
                                                  → 3E React Native
                                                  → 3F Flutter
                                                  → 3G .NET NuGet
                                                  → 3H docs / publish / launch
```

3D mirrors 3C: extract a shared module from the two existing cores, add one new backend (LiteRT), and wrap the lot in a single umbrella that exposes the same DVAIBridge surface as the iOS SDK.

---

## 1. Goals

1. Stand up `packages/dvai-bridge-android/` with a Gradle library module producing a single `co.deepvoiceai:dvai-bridge` AAR. Consumers integrate via:
   ```kotlin
   implementation("co.deepvoiceai:dvai-bridge:2.x.y")
   ```
2. Public API: `DVAIBridge` singleton (Kotlin `object`) that exposes the same 8-method surface as the iOS SDK (`start`, `stop`, `status`, `downloadModel`, `addProgressListener`, `removeProgressListener`, `getServerInfo`, plus the BoundServer return shape).
3. Backend selection at `start()`-time: `Auto` (default), `Llama`, `MediaPipe`, `LiteRT`. `Auto` picks the best backend at runtime based on device capability + supplied artifacts.
4. Three concrete backends, all production-quality:
   - **llama.cpp** via `android-llama-core` — already shipping on Capacitor.
   - **MediaPipe LLM** via `android-mediapipe-core` (post-3B uses the LiteRT-LM runtime under the hood).
   - **LiteRT** — new in 3D. Wraps Google's TFLite/LiteRT runtime for non-LLM (or generic LLM) `.tflite` checkpoints that don't fit MediaPipe's bundled-task format.
5. Ship pure-Kotlin instrumented tests proving a non-Capacitor consumer can `import co.deepvoiceai.bridge.DVAIBridge`, call `start()` against each backend, hit `http://127.0.0.1:38883/v1/chat/completions`, and get a response — three integration tests, one per backend, each gated on availability (env-var-supplied model URLs / artifact presence).
6. Reuse all existing JNI artifacts (`libllama.so`, `libmediapipe.so`) — 3D adds no native code, just the Kotlin wrapper layer + LiteRT (LiteRT ships its own `.so` via the LiteRT Maven artifact).

## 2. Non-goals (3D)

- **LiteRT model auto-download.** Same convention as CoreML in 3C: consumer supplies path to a `.tflite` (or `.litertlm`) on disk. Phase 3D ships docs pointing at Google's LiteRT model zoo.
- **LiteRT model conversion tooling.** Convert offline via `tf.lite.TFLiteConverter` / Google's AI Edge tooling. The SDK consumes pre-converted models only.
- **Publishing to Maven Central.** Phase 3D publishes to GitHub Packages Maven (`maven.pkg.github.com/Westenets/dvai-bridge`). Maven Central onboarding (Sonatype OSSRH) is deferred to Phase 3H or later — token-based authentication on GitHub Packages is good enough for early adopters.
- **Refactoring the existing core modules.** `android-llama-core` and `android-mediapipe-core` stay frozen except for surgical additions of new public symbols the SDK needs.
- **Anything iOS, .NET, RN, Flutter, or web.** 3D is Android-only.
- **React Native / Flutter wrappers consuming this SDK.** Those are 3E and 3F.
- **Wear OS / Android TV / Auto support.** Phone + tablet only (the platforms currently supported by the existing cores' `build.gradle` `minSdk`).
- **Renaming or restructuring the existing core packages.** They keep their current paths and Gradle module names.

## 3. Architecture

### 3.1 Package layout

```
packages/dvai-bridge-android/
├── package.json                                    # @dvai-bridge/android npm metadata
├── README.md                                       # synced via scripts/sync-package-meta.js
├── android/
│   ├── build.gradle.kts                            # the AAR module itself
│   ├── consumer-rules.pro
│   ├── proguard-rules.pro
│   └── src/
│       ├── main/
│       │   └── java/co/deepvoiceai/bridge/
│       │       ├── DVAIBridge.kt                   # the singleton + start()/stop()/etc.
│       │       ├── DVAIBridgeError.kt              # public sealed class
│       │       ├── DVAIBridgeConfig.kt             # StartOptions analog
│       │       ├── BoundServer.kt                  # StartResult analog
│       │       ├── ProgressEvent.kt                # Flow<ProgressEvent> emitter
│       │       ├── BackendKind.kt                  # enum: Auto, Llama, MediaPipe, LiteRT
│       │       ├── BackendSelector.kt              # picks backend at runtime
│       │       └── ReactiveState.kt                # StateFlow wrappers for baseUrl/port/isReady
│       ├── androidTest/
│       │   └── java/co/deepvoiceai/bridge/
│       │       ├── DVAIBridgeAPIShapeTest.kt
│       │       ├── BackendSelectorTest.kt
│       │       ├── ProgressEventTest.kt
│       │       └── RealModelIntegrationTest.kt     # llama / mediapipe / litert e2e
│       └── test/                                   # unit tests (no Android runtime)
```

The umbrella module depends on:
- `co.deepvoiceai:android-shared-core` (NEW — extracted in this phase, see §3.4)
- `co.deepvoiceai:android-llama-core` (existing)
- `co.deepvoiceai:android-mediapipe-core` (existing, now LiteRT-LM-backed per Phase 3B)
- `co.deepvoiceai:android-litert-core` (NEW — see §3.3)

Per the publishing plan, all four `*-core` modules ship to GitHub Packages Maven independently of the umbrella, so consumers who want only one backend can pull it on its own and skip the others.

### 3.2 Public API surface

```kotlin
import co.deepvoiceai.bridge.DVAIBridge
import co.deepvoiceai.bridge.BackendKind

// Singleton entry-point (Kotlin object)
val server = DVAIBridge.start(StartOptions(
    backend = BackendKind.Auto,                  // Auto | Llama | MediaPipe | LiteRT
    modelPath = "/path/to/model.gguf",           // required for Llama
    contextSize = 2048,
    threads = 4,
    httpBasePort = 38883,
    httpMaxPortAttempts = 16,
    corsOrigin = CORSConfig.Wildcard,
))

println(server.baseUrl)  // http://127.0.0.1:38883/v1
println(server.port)     // 38883
println(server.backend)  // BackendKind
println(server.modelId)

// Status
val info = DVAIBridge.status()
println("${info.running}, ${info.backend}, ${info.baseUrl}")

// Stop
DVAIBridge.stop()

// Progress events — Flow + classic listener API
val job = lifecycleScope.launch {
    DVAIBridge.progressFlow.collect { event -> println("progress: ${event.phase}") }
}

DVAIBridge.addProgressListener { event -> println(event) }
```

The 8 public methods exactly mirror the iOS SDK's surface (and the Capacitor JS shim's), differing only in idiomatic Kotlin (`Flow` instead of `AsyncStream`, `StateFlow` instead of `@Observable`).

### 3.3 LiteRT backend (`android-litert-core`)

NEW module under `packages/dvai-bridge-android-litert-core/`. Mirrors the layout of `android-llama-core` and `android-mediapipe-core`:

```
android-litert-core/
├── package.json
├── android/
│   ├── build.gradle.kts                           # depends on com.google.ai.edge.litert:litert
│   └── src/main/java/co/deepvoiceai/bridge/litert/core/
│       ├── PluginState.kt                         # boots HTTP + LiteRT engine
│       ├── LiteRTEngine.kt                        # wraps com.google.ai.edge.litert.Interpreter
│       ├── LiteRTHandlers.kt                      # implements DVAIHandlers
│       ├── LiteRTGenerator.kt                     # tokenize → forward → sample
│       ├── LiteRTSampler.kt                       # greedy + temp/top-p
│       └── LiteRTBackendError.kt
```

**Key constraints:**
- Use **LiteRT 1.x** (Google's renamed TFLite, latest stable). `com.google.ai.edge.litert:litert:1.x.y` from `mavenCentral()`.
- `Interpreter.runForMultipleInputsOutputs(inputs, outputs)` for generic ML models; for LLMs, use `LlmInferenceEngine` from `com.google.ai.edge.litert:litert-llm` if it's GA by Phase 3D's start.
- Tokenizer: bundle `com.huggingface.tokenizers:tokenizers-android:<latest>` (HuggingFace's Android-native tokenizer JNI wrapper) so we don't depend on Python conversion artifacts at runtime.
- Memory: explicit `Interpreter.close()` in `stop()`; consumer must call `DVAIBridge.stop()` to release ~1-3GB of LiteRT-LM tensors per the LiteRT lifecycle.

### 3.4 Shared-core extraction (`android-shared-core`)

NEW module — mirrors the iOS DVAISharedCore lift-out from Phase 3C. Today, both `android-llama-core` and `android-mediapipe-core` carry their own copies of:

- `HttpServer.kt` — Ktor CIO embedded server + port-fallback `tryBind()`
- `HandlerDispatch.kt` — generic JSON dispatch helpers + CORS handling
- `HandlerContext` (data class) — modelId / backendName tuple

3D extracts them into:

```
packages/dvai-bridge-android-shared-core/
├── package.json
├── android/
│   ├── build.gradle.kts                           # pure Kotlin, no native code
│   └── src/main/java/co/deepvoiceai/bridge/shared/core/
│       ├── HttpServer.kt                          # moved from llama-core
│       ├── HandlerDispatch.kt                     # moved (de-duplicated)
│       ├── HandlerContext.kt                      # moved
│       ├── DVAIHandlers.kt                        # interface (request/response shape)
│       └── CORSConfig.kt                          # public sealed class
```

Both existing cores then `implementation(project(":android-shared-core"))` and delete their local copies. The `dvai-bridge` umbrella also depends on `shared-core` directly so it can construct `HandlerContext` / `CORSConfig` without going through a backend module.

**Verification:** the existing capacitor-llama and capacitor-mediapipe instrumented tests must continue passing after the extraction with no API-shape change visible to consumers (the wrapper plugins only see public API).

### 3.5 Backend selector (Auto mode)

Same logic as the iOS SDK, adapted for Android:

```kotlin
object BackendSelector {
    fun resolve(opts: StartOptions, ctx: Context): BackendKind {
        if (opts.backend != BackendKind.Auto) return opts.backend

        // 1. If modelPath ends with .task and the file exists → MediaPipe.
        opts.modelPath?.takeIf { it.endsWith(".task") && File(it).exists() }?.let {
            return BackendKind.MediaPipe
        }
        // 2. If modelPath ends with .tflite or .litertlm → LiteRT.
        opts.modelPath?.takeIf { it.endsWith(".tflite") || it.endsWith(".litertlm") }?.let {
            return BackendKind.LiteRT
        }
        // 3. Default to llama.cpp (handles .gguf and is the universal fallback).
        return BackendKind.Llama
    }
}
```

### 3.6 Test strategy

**Unit tests** (`src/test/`, no Android runtime):
- `BackendSelectorTest` — every dispatch branch
- `DVAIBridgeAPIShapeTest` — reflection on public API surface
- `ProgressEventTest` — Flow + listener emission

**Instrumented tests** (`src/androidTest/`, requires emulator or device):
- `RealModelIntegrationTest.kt` — three test methods, one per backend:
  - `testLlamaBackendIntegration` — env-supplied `.gguf` (existing `SMOKE_MODEL_URL`)
  - `testMediaPipeBackendIntegration` — env-supplied `.task`
  - `testLiteRTBackendIntegration` — env-supplied `.tflite` or `.litertlm`
- Each downloads the model, calls `DVAIBridge.start(...)`, hits `/v1/chat/completions`, asserts non-empty.

Smoke env vars (mirror iOS `scripts/smoke.local.env` convention):
- `SMOKE_MODEL_URL` / `SMOKE_MODEL_SHA256` (llama)
- `SMOKE_MEDIAPIPE_MODEL_URL` (MediaPipe)
- `SMOKE_LITERT_MODEL_URL` (LiteRT)

CI runs all three on a Linux runner with `reactivecircus/android-emulator-runner@v2`. Same `.disabled` workflow technique we use for iOS during dev, re-enabled in Phase 3H.

## 4. Distribution

### 4.1 GitHub Packages Maven

`build.gradle.kts` (umbrella module):

```kotlin
publishing {
    publications {
        create<MavenPublication>("release") {
            groupId = "co.deepvoiceai"
            artifactId = "dvai-bridge"
            version = "2.x.y"
            from(components["release"])
        }
    }
    repositories {
        maven {
            name = "GitHubPackages"
            url = uri("https://maven.pkg.github.com/Westenets/dvai-bridge")
            credentials {
                username = project.findProperty("gpr.user") as String?
                    ?: System.getenv("GITHUB_ACTOR")
                password = project.findProperty("gpr.key") as String?
                    ?: System.getenv("GITHUB_TOKEN")
            }
        }
    }
}
```

Token in `~/.gradle/gradle.properties` per the publishing guide.

### 4.2 Consumer integration

```kotlin
// settings.gradle.kts
dependencyResolutionManagement {
    repositories {
        maven {
            url = uri("https://maven.pkg.github.com/Westenets/dvai-bridge")
            credentials {
                username = providers.gradleProperty("gpr.user").orNull
                password = providers.gradleProperty("gpr.key").orNull
            }
        }
    }
}

// app/build.gradle.kts
dependencies {
    implementation("co.deepvoiceai:dvai-bridge:2.x.y")
    // OR pick individual cores:
    implementation("co.deepvoiceai:android-llama-core:2.x.y")
    implementation("co.deepvoiceai:android-litert-core:2.x.y")
}
```

## 5. Versioning

Phase 3D ships under the existing `2.x.y` line — Phase 3 was already tagged at v2.0.0 to represent the initial native SDK family. 3D is a minor bump (e.g. `2.1.0`) since it adds the Android SDK without breaking any iOS / Capacitor consumers. Per the project's phase-boundary tagging policy, the tagged commit goes in at the end of 3D's last task once the umbrella + LiteRT + shared-core extraction are all green on instrumented tests.

## 6. Open questions

1. **LiteRT-LM artifact naming:** Phase 3B already migrated `android-mediapipe-core` to use LiteRT-LM 0.10.x under the hood. Should `android-litert-core` reuse that runtime or pull a separate `litert-llm` Maven artifact? Decision deferred until 3D plan-writing — depends on whether MediaPipe's bundled LiteRT-LM exposes its raw `Interpreter` to non-MediaPipe consumers.
2. **HuggingFace tokenizer artifact:** `tokenizers-android` is on JitPack, not Maven Central. Acceptable for a JNI-bound dependency in a research-grade SDK, or do we need to vendor the tokenizer JNI ourselves? Default: depend on JitPack via `maven { url = uri("https://jitpack.io") }` in the consumer's settings.
3. **`DVAIBridge` as `object` vs. `class` with `getInstance(context)`:** Kotlin idiom favors `object` (singleton), but Android often needs an `applicationContext` for asset access. Resolution: top-level `object` whose first call to `start()` accepts a `Context` and stores `applicationContext` internally — same pattern as Firebase Android SDK.

## 7. References

- Phase 3 foundation spec: [docs/superpowers/specs/2026-04-26-phase3-foundation-design.md](../specs/2026-04-26-phase3-foundation-design.md)
- Phase 3C iOS SDK spec (3D mirrors this structure): [docs/superpowers/specs/2026-04-26-phase3c-ios-native-sdk-design.md](2026-04-26-phase3c-ios-native-sdk-design.md)
- LiteRT-LM Phase 3B plan: [docs/superpowers/plans/2026-04-26-phase3-foundation.md](../plans/2026-04-26-phase3-foundation.md)
- Existing Android cores: `packages/dvai-bridge-android-llama-core/`, `packages/dvai-bridge-android-mediapipe-core/`
- PUBLISHING.md (gitignored) — Maven publish flow stub already drafted under "Maven — Android AAR (Phase 3D)"
