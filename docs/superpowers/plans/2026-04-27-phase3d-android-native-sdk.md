# Phase 3D — Android Native SDK Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to execute this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up `packages/dvai-bridge-android/` — a top-level Android SDK that wraps `android-llama-core` + `android-mediapipe-core` (existing) plus a new `android-litert-core`, exposes a unified `DVAIBridge` Kotlin object API, and ships via Maven (GitHub Packages).

**Architecture:** Multi-module Gradle layout. New `android-shared-core` extracts `HttpServer` + `HandlerDispatch` + `HandlerContext` + `DVAIHandlers` + `CORSConfig` out of the two existing cores so the umbrella + a future LiteRT-only consumer can compose them without duplication. `dvai-bridge-android` is the umbrella AAR (`co.deepvoiceai:dvai-bridge`). LiteRT is a new third backend mirroring how CoreML was the new backend in Phase 3C.

**Tech Stack:** Kotlin 2.x / Gradle 8.x / Android Gradle Plugin 8.x / Ktor CIO (HTTP server, transitively from cores) / Coroutines + `Flow` (progress events) / `StateFlow` (reactive state) / LiteRT 1.x (`com.google.ai.edge.litert:litert`) / HuggingFace tokenizers (Android JNI, JitPack distribution).

**Spec:** [`docs/superpowers/specs/2026-04-27-phase3d-android-native-sdk-design.md`](../specs/2026-04-27-phase3d-android-native-sdk-design.md)

**Branch:** `feat/phase3d-android-native-sdk` off `main`. Implementation done in worktree `.worktrees/phase3d-android-native-sdk`.

**Resolution of spec open questions (decided here, applied throughout the plan):**

1. **LiteRT-LM artifact:** `android-litert-core` pulls a separate `com.google.ai.edge.litert:litert` + `litert-llm` directly, NOT the bundled `litertlm-android` that `android-mediapipe-core` uses. Reason: keeps the litert-core dependency surface clean and lets it stand alone for non-MediaPipe consumers. mediapipe-core stays on the bundled `litertlm-android` because that artifact's `LlmInferenceTask` API is what mediapipe-core's existing surface is shaped for.
2. **HuggingFace tokenizers-android:** Use JitPack distribution — `com.github.huggingface:tokenizers-android:<latest>`. Document that consumers need `maven { url = uri("https://jitpack.io") }` in their `settings.gradle.kts` repos. Vendoring the JNI is out of scope for 3D.
3. **`DVAIBridge` shape:** Kotlin `object` with a one-time `init(applicationContext)` call — Firebase pattern. First `start()` requires the context already be set; throws `IllegalStateException` if not. Wrappers (Capacitor / RN / Flutter) call `init()` from their plugin's `load()` lifecycle.

**Phase boundaries (subagent-friendly groupings):**

- **Tasks 1-4:** `android-shared-core` extraction. Move shared types out of llama-core / mediapipe-core, verify capacitor wrappers still pass.
- **Tasks 5-9:** `android-litert-core` — new LiteRT backend module (engine + generator + sampler + handlers + plugin state).
- **Tasks 10-15:** `dvai-bridge-android` umbrella — public API (DVAIBridge object, BackendKind, BackendSelector, BoundServer, DVAIBridgeConfig, ProgressEvent, ReactiveState).
- **Tasks 16-17:** Tests — unit tests + real-model instrumented integration tests (3 backends).
- **Tasks 18-19:** Docs (android-native-sdk.md guide + migration guide entry) + CI re-enable.
- **Task 20:** Maven publish config + CHANGELOG + version bump + tag.

**Apply Phase 3A/3C lessons up-front (read before starting):**

1. **Mirror iOS DVAISharedCore extraction.** Same type names where possible (`HandlerContext`, `DVAIHandlers`, `CORSConfig`, `HttpServer`) so cross-platform readers can map between Swift and Kotlin in their head.
2. **Each `*-core` package gets its own Gradle module** with its own `build.gradle.kts`. Don't try to nest them inside the umbrella's module.
3. **Per-developer `~/.gradle/gradle.properties`** holds the GitHub Packages credentials (`gpr.user` / `gpr.key`); never commit them. PUBLISHING.md already documents this.
4. **Public visibility is explicit.** Kotlin defaults to `public` but spell it out on the umbrella's API surface for clarity / IDE search hits.
5. **`@JvmStatic` + `@JvmField` on the umbrella's static surface** so Java consumers can call `DVAIBridge.start(...)` without `INSTANCE`.
6. **Resolve dependencies to LATEST stable** at the time of task execution. The user's standing instruction is "always pin to latest" for all 3rd-party deps / build tools / OS targets. Each task that adds a dependency must verify the latest version on Maven Central / Google Maven / JitPack.

---

## Task 1: Scaffold `android-shared-core` package

**Intent:** Create a new Gradle library module that will receive the moved types in Task 2.

**Files:**
- Create: `packages/dvai-bridge-android-shared-core/package.json`
- Create: `packages/dvai-bridge-android-shared-core/android/build.gradle.kts`
- Create: `packages/dvai-bridge-android-shared-core/android/src/main/AndroidManifest.xml`
- Create: `packages/dvai-bridge-android-shared-core/android/.gitignore`

**Steps:**

- [ ] Mirror the directory layout of `dvai-bridge-android-llama-core/` minus the JNI bits. Use the same Kotlin / AGP / minSdk / targetSdk versions.
- [ ] `package.json` follows the exact shape of `dvai-bridge-android-llama-core/package.json`, name `@dvai-bridge/android-shared-core`, version `2.x.y` (sync via `scripts/sync-versions.js` after the version bump).
- [ ] `build.gradle.kts` declares `co.deepvoiceai.bridge.shared.core` as the namespace, depends on **only** Kotlin stdlib + Coroutines + Ktor CIO (the bare minimum needed by `HttpServer.kt`). No JNI, no llama, no mediapipe.
- [ ] Add a publishing block ready for GitHub Packages Maven (matches the per-package convention; see Task 20 for the full block).
- [ ] Wire the new module into the root `settings.gradle.kts` if applicable (the monorepo doesn't currently use a root settings.gradle — each package is independent — so this is a no-op for now).

**Acceptance:** `cd packages/dvai-bridge-android-shared-core/android && ./gradlew assembleRelease` produces an empty AAR. `pnpm install` recognizes the new package via npm-graph integration.

---

## Task 2: Move shared types into `android-shared-core`

**Intent:** Move the duplicated `HttpServer.kt` + `HandlerDispatch.kt` + supporting types out of llama-core and mediapipe-core, into the new shared-core.

**Files (move + namespace rewrite):**

From `packages/dvai-bridge-android-llama-core/android/src/main/java/co/deepvoiceai/bridge/llama/core/`:
- Move: `HttpServer.kt` → shared-core's `co.deepvoiceai.bridge.shared.core` package
- Move: `HandlerDispatch.kt` → shared-core
- Extract `HandlerContext` + `DVAIHandlers` (interface) + `CORSConfig` to their own files in shared-core (currently they're embedded in llama-core's HandlerDispatch.kt or PluginState.kt).

From `packages/dvai-bridge-android-mediapipe-core/android/src/main/java/co/deepvoiceai/bridge/mediapipe/core/`:
- Delete: `HttpServer.kt` (duplicate — replaced by shared-core's)
- Delete: `HandlerDispatch.kt` (duplicate — replaced)

**Steps:**

- [ ] Read the existing llama-core `HttpServer.kt` + `HandlerDispatch.kt` end-to-end.
- [ ] Create shared-core versions verbatim except for the `package` declaration at the top → `co.deepvoiceai.bridge.shared.core`.
- [ ] Extract `HandlerContext`, `DVAIHandlers` interface, `CORSConfig` (sealed class with `Wildcard` / `Exact(String)` / `Allowlist(List<String>)` cases) into their own `*.kt` files in shared-core.
- [ ] Update llama-core's `LlamaHandlers.kt` and `PluginState.kt` to `import co.deepvoiceai.bridge.shared.core.*` for the moved types; delete the now-moved `HttpServer.kt` + `HandlerDispatch.kt` from llama-core.
- [ ] Same for mediapipe-core.
- [ ] Update llama-core's and mediapipe-core's `build.gradle` to add `implementation(project(":dvai-bridge-android-shared-core"))` — but since each package is its own Gradle root, this becomes `implementation files("../../dvai-bridge-android-shared-core/android/build/outputs/aar/...")` OR (preferred) a published Maven coordinate during dev via local Maven repo.

> **Mac-side note:** The Android cores aren't currently nested under a single `settings.gradle`. Cross-module dependencies need either: (a) a root settings.gradle.kts that includes both, or (b) `mavenLocal()` + publish-to-local during dev. Choose (b) per-package — it matches how the Capacitor wrappers depend on the cores today (via `implementation` of a versioned npm-distributed AAR). For development, both packages need to publish to mavenLocal first, then the umbrella consumes them. Add a `scripts/android-publish-local.sh` helper to publish all four cores to mavenLocal in one shot.

**Acceptance:**
- `./gradlew :dvai-bridge-android-shared-core:assembleRelease` → empty AAR with the moved types.
- `./gradlew :dvai-bridge-android-llama-core:assembleRelease` → llama-core AAR resolves shared-core via mavenLocal.
- `./gradlew :dvai-bridge-android-mediapipe-core:assembleRelease` → ditto.

---

## Task 3: Verify Capacitor wrappers still build + test green

**Intent:** Make sure the Phase 3A capacitor-llama / capacitor-mediapipe wrappers still build green after the shared-core extraction.

**Steps:**

- [ ] Run `cd packages/dvai-bridge-capacitor-llama/android && ./gradlew test` — should pass with no API changes visible at the Capacitor wrapper level.
- [ ] Run the same for `dvai-bridge-capacitor-mediapipe`.
- [ ] If anything fails, the import surface from llama-core / mediapipe-core might have leaked the shared types' package. Update those imports — the wrapper code shouldn't need to care about the new package boundary.
- [ ] Run the Capacitor smoke test: `bash scripts/verify-cap-sync.sh`.

**Acceptance:** All Capacitor Android tests pass; `verify-cap-sync.sh` exits 0.

---

## Task 4: Local Maven publishing helper

**Intent:** Add the dev-time helper that publishes all five (eventually) Android packages to `~/.m2/repository` so the umbrella's Gradle resolves them locally.

**Files:**
- Create: `scripts/android-publish-local.sh`
- Update: `scripts/mac-side-build.sh` — recognize `android-shared-core`, `android-litert-core`, `android-bridge` targets.

**Steps:**

- [ ] Script iterates each `packages/dvai-bridge-android-*/android/` and runs `./gradlew publishToMavenLocal`.
- [ ] Order matters: shared-core first, then llama-core / mediapipe-core / litert-core, then the umbrella `dvai-bridge-android`.
- [ ] Each package's `build.gradle.kts` needs a `publishToMavenLocal` task; ensure the publishing block (added in Task 1 for shared-core) is also added to the existing two cores. Refactor the publishing block into a shared `buildSrc/` Gradle convention plugin if desired — out of scope for this task; just copy-paste for now.

**Acceptance:** `bash scripts/android-publish-local.sh` exits 0; `ls ~/.m2/repository/co/deepvoiceai/` lists all the packages.

---

## Task 5: Scaffold `android-litert-core` package

**Intent:** Create the new LiteRT backend module — same shape as android-llama-core minus the JNI/native code (LiteRT ships its own `.so` via the Maven artifact).

**Files:**
- Create: `packages/dvai-bridge-android-litert-core/package.json`
- Create: `packages/dvai-bridge-android-litert-core/android/build.gradle.kts`
- Create: `packages/dvai-bridge-android-litert-core/android/src/main/AndroidManifest.xml`
- Create: `packages/dvai-bridge-android-litert-core/android/.gitignore`

**Steps:**

- [ ] Namespace `co.deepvoiceai.bridge.litert.core`.
- [ ] Dependencies (verify latest at task time):
  - `com.google.ai.edge.litert:litert:1.x.y` (core LiteRT runtime — Maven Central)
  - `com.google.ai.edge.litert:litert-llm:1.x.y` (LLM-specific helpers, if GA — fall back to manual `Interpreter` use if not)
  - `com.github.huggingface:tokenizers-android:<latest>` (HF JNI tokenizer — JitPack)
  - `implementation(project(":dvai-bridge-android-shared-core"))` via mavenLocal coordinate
  - Coroutines + Ktor CIO (transitively via shared-core)
- [ ] minSdk: same as the other Android cores (likely 26). targetSdk: latest stable (verify at task time).
- [ ] `consumer-rules.pro` declares the LiteRT classes that should not be R8-stripped by consumers.

**Acceptance:** `./gradlew :dvai-bridge-android-litert-core:assembleRelease` produces a (currently empty) AAR.

---

## Task 6: Implement `LiteRTEngine`

**Intent:** Wrap `com.google.ai.edge.litert.Interpreter` (or `LlmInferenceEngine` if the litert-llm artifact is GA) with a clean Kotlin surface for token-by-token generation. Mirror `CoreMLEngine.swift`'s shape.

**File:**
- Create: `packages/dvai-bridge-android-litert-core/android/src/main/java/co/deepvoiceai/bridge/litert/core/Internal/LiteRTEngine.kt`

**Steps:**

- [ ] Class signature: `internal class LiteRTEngine(modelPath: String, contextSize: Int = 2048, eosTokenId: Int)`. `init { ... }` loads the `.tflite` / `.litertlm` file via `Interpreter(File(modelPath), Interpreter.Options())` and inspects input/output tensor shapes.
- [ ] Public methods:
  - `fun runStep(token: Int, kvCachePosition: Int): FloatArray` — feeds the new token, returns the logits vector.
  - `fun close()` — releases the Interpreter.
- [ ] Causal-mask wiring: same conventions as Apple's stateful checkpoints — `[1, 1, 1, kvCachePosition+1]` Float16/Float32 tensor of zeros for unmasked autoregressive decoding. LiteRT models from Google's AI Edge model zoo follow Apple's conventions for this input.
- [ ] Use `ByteBuffer.allocateDirect()` + `.asIntBuffer()` for the input_ids tensor and `.asFloatBuffer()` for the mask.
- [ ] Wrap input/output in `Map<String, Any>` for `Interpreter.runForMultipleInputsOutputs(inputs, outputs)`.

**Acceptance:** A unit test using a tiny fixture .tflite (created with `tf.lite.TFLiteConverter` from a 100-param model — author offline, commit to `packages/dvai-bridge-android-litert-core/android/src/test/resources/`) exercises `runStep()` and verifies the output FloatArray length matches the vocab dimension.

---

## Task 7: Implement `LiteRTSampler`

**Intent:** Greedy + temperature/top-p/top-k sampling. Pure Kotlin, no LiteRT dependency.

**File:**
- Create: `packages/dvai-bridge-android-litert-core/android/src/main/java/co/deepvoiceai/bridge/litert/core/Internal/LiteRTSampler.kt`

**Steps:**

- [ ] `internal class LiteRTSampler(temperature: Float, topP: Float, topK: Int)`.
- [ ] `fun sample(logits: FloatArray): Int`:
  - If `temperature == 0` → argmax.
  - Else: divide logits by temperature, softmax, optional top-k truncation, optional top-p (nucleus) truncation, multinomial sample using `Random.Default` (deterministic when caller seeds).
- [ ] Mirror the iOS `CoreMLSampler.swift` math 1:1 — copy the algorithm comments verbatim where useful.

**Acceptance:** Unit test verifies argmax for temperature=0 and that top-k=1 + temperature>0 still returns argmax.

---

## Task 8: Implement `LiteRTGenerator` + `LiteRTHandlers` + `LiteRTPluginState`

**Intent:** Thread the engine + sampler + tokenizer into a generator, expose it via DVAIHandlers, boot the HTTP server.

**Files:**
- Create: `LiteRTGenerator.kt` (Internal) — prefill loop + decode loop, mirrors `CoreMLGenerator.swift`.
- Create: `LiteRTHandlers.kt` (public via shared-core's `DVAIHandlers` interface).
- Create: `LiteRTPluginState.kt` (public — top-level entry: load tokenizer, build engine, build sampler, build generator, bind HTTP server, install routes).
- Create: `LiteRTBackendError.kt` — sealed class mirroring `CoreMLBackendError.swift`.

**Steps:**

- [ ] `LiteRTGenerator`: tokenize prompt with HuggingFace tokenizer → prefill loop calling `engine.runStep(token, kvPos)` for each prompt token → decode loop sampling next token with `sampler` and feeding back. Stop on EOS or `maxNewTokens`.
- [ ] `LiteRTHandlers` implements the `DVAIHandlers` interface from shared-core. Provides `chatCompletion`, `completion`, `models` request handlers.
- [ ] `LiteRTPluginState` is the public boot entry: takes a `Map<String, Any?>` opts, returns a `Map<String, Any?>` start-result (mirrors llama-core's `PluginState`). Internal: `Mutex` + lifecycle state.
- [ ] CORS / port-fallback / route installation all delegate to shared-core's `HttpServer`.

**Acceptance:** Boot test (instrumented or not) — calling `LiteRTPluginState().start(mapOf("modelPath" to fixture))` returns a baseUrl, hitting `/v1/models` returns the model id, and `stop()` cleanly shuts down.

---

## Task 9: LiteRT unit tests

**Intent:** Pure-JVM unit tests for the LiteRT backend that don't require an emulator.

**Files:**
- Create: `android/src/test/java/co/deepvoiceai/bridge/litert/core/LiteRTSamplerTest.kt`
- Create: `android/src/test/java/co/deepvoiceai/bridge/litert/core/LiteRTGeneratorMockTest.kt` (uses a fake `LiteRTEngine` returning canned logits to exercise the generator's decode loop)

**Steps:**

- [ ] Sampler tests: argmax, temperature affects distribution, top-k truncates, top-p truncates.
- [ ] Generator mock test: feed canned logits arrays, assert tokens are generated in order, EOS stops the loop.

**Acceptance:** `./gradlew :dvai-bridge-android-litert-core:test` passes.

---

## Task 10: Scaffold `dvai-bridge-android` umbrella package

**Intent:** Create the umbrella Gradle module that depends on all four cores (shared / llama / mediapipe / litert) and exposes the public DVAIBridge API.

**Files:**
- Create: `packages/dvai-bridge-android/package.json`
- Create: `packages/dvai-bridge-android/android/build.gradle.kts`
- Create: `packages/dvai-bridge-android/android/src/main/AndroidManifest.xml`
- Create: `packages/dvai-bridge-android/README.md`

**Steps:**

- [ ] `package.json`: name `@dvai-bridge/android`, mirrors the shape of all the others.
- [ ] `build.gradle.kts` namespace `co.deepvoiceai.bridge`. minSdk + targetSdk + Kotlin/AGP versions match the cores.
- [ ] Dependencies:
  - `implementation("co.deepvoiceai:android-shared-core:2.x.y")` (mavenLocal in dev)
  - `implementation("co.deepvoiceai:android-llama-core:2.x.y")`
  - `implementation("co.deepvoiceai:android-mediapipe-core:2.x.y")`
  - `implementation("co.deepvoiceai:android-litert-core:2.x.y")`
- [ ] Publishing block prepared for GitHub Packages Maven (full block in Task 20).

**Acceptance:** `./gradlew :dvai-bridge-android:assembleRelease` produces an empty AAR with all four cores transitively pulled.

---

## Task 11: Public API — `BackendKind` + `BackendSelector`

**Intent:** Define the backend enum and the auto-resolution logic. Mirrors iOS `BackendKind.swift` + `BackendSelector.swift`.

**Files:**
- Create: `packages/dvai-bridge-android/android/src/main/java/co/deepvoiceai/bridge/BackendKind.kt`
- Create: `packages/dvai-bridge-android/android/src/main/java/co/deepvoiceai/bridge/BackendSelector.kt`

**Steps:**

- [ ] `enum class BackendKind { Auto, Llama, MediaPipe, LiteRT }`.
- [ ] `BackendSelector.resolve(opts: StartOptions, ctx: Context): BackendKind` — see spec §3.5 for the resolution rules.

**Acceptance:** Unit tests cover all six dispatch branches (each backend hit + auto via three file extensions).

---

## Task 12: Public API — `DVAIBridgeConfig` + `BoundServer` + `DVAIBridgeError`

**Intent:** Public data classes / sealed classes for the API surface.

**Files:**
- Create: `DVAIBridgeConfig.kt` — data class `StartOptions(backend, modelPath, mmprojPath, contextSize, threads, gpuLayers, httpBasePort, httpMaxPortAttempts, corsOrigin, ...)`.
- Create: `BoundServer.kt` — data class `BoundServer(baseUrl: String, port: Int, backend: BackendKind, modelId: String)`.
- Create: `DVAIBridgeError.kt` — `sealed class DVAIBridgeError : Exception()` with cases mirroring iOS: `AlreadyStarted`, `ConfigurationInvalid`, `ModelLoadFailed`, `BackendUnavailable`, `BackendError`, `ChecksumMismatch`, `DownloadFailed`.

**Acceptance:** Reflection-based API-shape unit test asserts the cases + properties exist with the expected types.

---

## Task 13: Public API — `ProgressEvent` + `Flow` + listener API

**Intent:** Progress event broadcasting via Kotlin `Flow` (idiomatic) + classic listener API (Java-friendly).

**Files:**
- Create: `ProgressEvent.kt` — sealed class with cases `Started`, `Progress(percent: Float, message: String)`, `Completed`, `Failed(error: DVAIBridgeError)`.
- Create: `ProgressBroadcaster.kt` — internal — maintains a `MutableSharedFlow<ProgressEvent>` and a `MutableList<(ProgressEvent) -> Unit>` listener registry.

**Steps:**

- [ ] `Flow` API: `DVAIBridge.progressFlow: SharedFlow<ProgressEvent>` (read-only public Flow).
- [ ] Listener API: `DVAIBridge.addProgressListener(listener)` / `removeProgressListener(listener)`.
- [ ] Both surfaces emit the same events in sync.

**Acceptance:** Unit test using `runTest { ... }` captures emissions on both surfaces simultaneously.

---

## Task 14: Public API — `DVAIBridge` object + `start()` / `stop()` / `status()` / `downloadModel()`

**Intent:** The 8-method singleton entry point. This is the single biggest task — wires everything together.

**File:**
- Create: `packages/dvai-bridge-android/android/src/main/java/co/deepvoiceai/bridge/DVAIBridge.kt`

**Steps:**

- [ ] `object DVAIBridge` — Kotlin singleton.
- [ ] `fun init(applicationContext: Context)` — store the `applicationContext`. First-call required before `start()`. Throws `IllegalStateException` if `start()` called before `init()`.
- [ ] `suspend fun start(opts: StartOptions): BoundServer` — resolves backend via `BackendSelector`, instantiates the right plugin state (LlamaPluginState / MediaPipePluginState / LiteRTPluginState), boots, returns BoundServer.
- [ ] `suspend fun stop()` — delegates to the active plugin state.
- [ ] `suspend fun status(): StatusInfo` — returns `(running: Boolean, baseUrl: String?, backend: BackendKind?, modelId: String?)`.
- [ ] `suspend fun downloadModel(opts: DownloadOptions): DownloadResult` — wraps the existing `ModelDownloader.kt` from llama-core (move to shared-core as part of this task — modeled on the iOS approach).
- [ ] `progressFlow`, `addProgressListener`, `removeProgressListener` — proxy to ProgressBroadcaster.
- [ ] `getServerInfo()` — same as `status()` but synchronous (returns last-known cached state).

**Acceptance:** API-shape reflection test asserts all 8 methods + the right signatures. End-to-end smoke (Llama backend, real model from `SMOKE_MODEL_URL`) returns a non-empty chat completion.

---

## Task 15: ReactiveState (`StateFlow` wrappers)

**Intent:** Mirror iOS `DVAIBridgeReactiveState` — Compose / Lifecycle-friendly observables.

**File:**
- Create: `packages/dvai-bridge-android/android/src/main/java/co/deepvoiceai/bridge/ReactiveState.kt`

**Steps:**

- [ ] `class DVAIBridgeReactiveState` exposes `val isReady: StateFlow<Boolean>`, `val baseUrl: StateFlow<String?>`, `val port: StateFlow<Int?>`, `val backend: StateFlow<BackendKind?>`.
- [ ] Updated by DVAIBridge internally on every `start()` / `stop()`.
- [ ] `DVAIBridge.reactive: DVAIBridgeReactiveState` accessor.

**Acceptance:** Unit test using `runTest` collects from each StateFlow, calls `start()` (mocked), asserts emission order.

---

## Task 16: Unit tests — API shape, BackendSelector, ProgressBroadcaster

**Intent:** Pure-JVM unit tests under `src/test/`. No emulator.

**Files:**
- Create: `android/src/test/java/co/deepvoiceai/bridge/DVAIBridgeAPIShapeTest.kt` — reflection on all public types.
- Create: `android/src/test/java/co/deepvoiceai/bridge/BackendSelectorTest.kt` — every dispatch branch.
- Create: `android/src/test/java/co/deepvoiceai/bridge/ProgressBroadcasterTest.kt` — Flow + listener parity.

**Acceptance:** `./gradlew :dvai-bridge-android:test` passes.

---

## Task 17: Real-model integration tests

**Intent:** Three instrumented tests under `src/androidTest/`, one per backend. Mirror iOS `RealModelIntegrationTest.swift`.

**File:**
- Create: `packages/dvai-bridge-android/android/src/androidTest/java/co/deepvoiceai/bridge/RealModelIntegrationTest.kt`

**Steps:**

- [ ] Three test methods: `testLlamaBackendIntegration`, `testMediaPipeBackendIntegration`, `testLiteRTBackendIntegration`.
- [ ] Each reads its model URL from `BuildConfig.SMOKE_*` (injected via Gradle `buildConfigField` from per-developer `~/.gradle/gradle.properties` or CI env). Skip via `Assume.assumeTrue` when missing.
- [ ] Each downloads → calls `DVAIBridge.start(...)` → posts to `/v1/chat/completions` → asserts non-empty response.
- [ ] Use OkHttp 4.x for the HTTP client (already a transitive dep of Ktor).

**Acceptance:** All three pass on a Pixel-class API 33+ emulator with the env vars set; skip cleanly when env vars are missing.

---

## Task 18: Docs — `android-native-sdk.md` + migration entry

**Intent:** Public documentation under `docs/guide/`.

**Files:**
- Create: `docs/guide/android-native-sdk.md` (mirrors `docs/guide/ios-native-sdk.md`)
- Update: `docs/migration/v1.6-to-v2.0.md` — add an Android-side section noting the `co.deepvoiceai:dvai-bridge` umbrella + shared-core.
- Update: `docs/.vitepress/config.ts` — add the new guide page to the sidebar.

**Steps:**

- [ ] android-native-sdk.md sections: Overview, Installation (Gradle + Maven), Quickstart, BackendKind table, Auto-resolution rules, Reactive state with Compose example, Progress events, Errors table, Tests, Reference. Mirror the iOS doc's structure 1:1 except for Kotlin idioms.
- [ ] Migration guide: capacitor-llama / capacitor-mediapipe consumers see no API change because of the shared-core extraction (internal refactor only). Direct `android-llama-core` consumers must add `import co.deepvoiceai.bridge.shared.core.*` for the moved types.

**Acceptance:** `pnpm run docs:dev` shows the new page in the sidebar; no broken links.

---

## Task 19: CI re-enable + Android smoke matrix

**Intent:** Re-enable the GitHub Actions workflows that were disabled during dev (per the user's prior instruction), add an Android smoke job that exercises the umbrella's instrumented test on an emulator.

**Files:**
- Update: `.github/workflows/*.yml.disabled` → rename back to `.yml`.
- Create or update: `.github/workflows/smoke-android.yml` — Linux runner with `reactivecircus/android-emulator-runner@v2`, runs `./gradlew :dvai-bridge-android:connectedAndroidTest`.

**Steps:**

- [ ] Identify which workflows are `.yml.disabled` via `ls .github/workflows/`.
- [ ] Rename them back. Verify they're scoped sensibly (some may target Mac for iOS — those stay enabled).
- [ ] New smoke-android workflow uses an emulator-runner cache. Pulls the SMOKE_* env from repo secrets.

**Acceptance:** A test PR triggers the workflows; they pass.

---

## Task 20: Maven publish config + version bump + tag

**Intent:** Wire up GitHub Packages Maven publishing for all five Android packages, bump version, tag.

**Files:**
- Update: `packages/dvai-bridge-android-shared-core/android/build.gradle.kts` — add publishing block.
- Update: `packages/dvai-bridge-android-llama-core/android/build.gradle.kts` — add publishing block (if not already there from 3A).
- Update: `packages/dvai-bridge-android-mediapipe-core/android/build.gradle.kts` — same.
- Update: `packages/dvai-bridge-android-litert-core/android/build.gradle.kts` — same.
- Update: `packages/dvai-bridge-android/android/build.gradle.kts` — same.
- Update: `package.json` (root) — bump to `2.x.0` (Phase 3D minor bump).
- Update: `CHANGELOG.md` — new `## [2.x.0] — YYYY-MM-DD` section.
- Update: `PUBLISHING.md` (gitignored) — flesh out the "Maven — Android AAR (Phase 3D)" section now that there are real artifacts.

**Steps:**

- [ ] Standard publishing block (consistent across all five):
  ```kotlin
  publishing {
      publications {
          create<MavenPublication>("release") {
              groupId = "co.deepvoiceai"
              artifactId = project.name.removePrefix("dvai-bridge-")
              version = property("dvaiBridgeVersion") as String
              afterEvaluate { from(components["release"]) }
          }
      }
      repositories {
          maven {
              name = "GitHubPackages"
              url = uri("https://maven.pkg.github.com/Westenets/dvai-bridge")
              credentials {
                  username = (project.findProperty("gpr.user") as String?) ?: System.getenv("GITHUB_ACTOR")
                  password = (project.findProperty("gpr.key") as String?) ?: System.getenv("GITHUB_TOKEN")
              }
          }
      }
  }
  ```
- [ ] Run `node scripts/sync-versions.js` + `node scripts/sync-package-meta.js` after the root version bump.
- [ ] CHANGELOG entry covers the umbrella + LiteRT + shared-core extraction.
- [ ] `git commit -am "chore: bump versions to v2.x.0"` then `git tag -a v2.x.0 -m "v2.x.0 — Phase 3D Android Native SDK"` then `git push && git push --tags` — per the user's tag-with-commit policy.

**Acceptance:**
- `pnpm install` succeeds at the new version.
- `bash scripts/verify-cap-sync.sh` exits 0.
- The five Maven publications can be dry-run with `./gradlew publishReleasePublicationToGitHubPackagesRepository --dry-run`.
- The user manually publishes via the PUBLISHING.md flow when ready.

---

## Test strategy summary

| Layer | Tool | Where |
|---|---|---|
| Pure Kotlin unit tests | JUnit 5 + kotlinx-coroutines-test | `src/test/` of each module |
| Instrumented integration tests | AndroidJUnit4 + Espresso | `src/androidTest/` of `dvai-bridge-android` only |
| Capacitor regression | existing `verify-cap-sync.sh` | repo-root script |
| CI matrix | `reactivecircus/android-emulator-runner@v2` (Linux) | `.github/workflows/smoke-android.yml` |

## Risk register

1. **`com.google.ai.edge.litert:litert-llm` GA status uncertain.** If it's still in alpha at 3D start, fall back to manual `Interpreter`-based generation — slower implementation but feasible.
2. **JitPack outage.** HuggingFace tokenizers via JitPack means a JitPack failure breaks consumer builds. Document a workaround (vendoring the AAR) in the migration guide. Long-term, vendor it ourselves once Phase 3D ships.
3. **mavenLocal / cross-package dependency churn.** Five packages publishing to the same local Maven repo + each having its own Gradle root means version mismatches surface easily. Add a `scripts/verify-android-versions.sh` that reads each `package.json`'s `version` and asserts they're all equal.
4. **Emulator flakiness on CI.** Real-model instrumented tests can hang downloading large models. Set per-test timeouts to 25 minutes (matches iOS's 30) and use `Assume.assumeTrue` for env-var gating.

## Out-of-scope (deferred to later phases)

- React Native (3E), Flutter (3F), .NET (3G) wrappers around this SDK.
- Maven Central Sonatype OSSRH onboarding (3H or later).
- Wear OS / Android TV / Auto support.
- Vendoring the HuggingFace tokenizer JNI (3D ships JitPack-distributed; vendor in a follow-up if JitPack causes friction).
- Renaming or restructuring existing `android-llama-core` / `android-mediapipe-core` packages beyond the Task-2 import surgery.

## References

- Spec: [docs/superpowers/specs/2026-04-27-phase3d-android-native-sdk-design.md](../specs/2026-04-27-phase3d-android-native-sdk-design.md)
- iOS counterpart spec (same architecture, 3D mirrors): [docs/superpowers/specs/2026-04-26-phase3c-ios-native-sdk-design.md](../specs/2026-04-26-phase3c-ios-native-sdk-design.md)
- iOS counterpart plan: [docs/superpowers/plans/2026-04-26-phase3c-ios-native-sdk.md](2026-04-26-phase3c-ios-native-sdk.md)
- Phase 3 foundation (3A + 3B context): [docs/superpowers/specs/2026-04-26-phase3-foundation-design.md](../specs/2026-04-26-phase3-foundation-design.md)
- Existing Android cores: `packages/dvai-bridge-android-llama-core/`, `packages/dvai-bridge-android-mediapipe-core/`
- PUBLISHING.md (gitignored, repo root) — Maven publish flow
