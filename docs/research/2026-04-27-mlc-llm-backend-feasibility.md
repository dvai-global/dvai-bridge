# MLC LLM as a DVAI-Bridge Backend — Feasibility & Scope

**Status:** Research-only. Not a spec. Not a plan. Decision input for the Phase 3 backlog.
**Date:** 2026-04-27
**Author:** research agent (no code changes; controlling agent reviews + commits)
**Scope:** Could MLC LLM (https://llm.mlc.ai/) become a peer of `llama-core` / `mlx-core` / `mediapipe-core` / `litert-core` — i.e. a `*-core` package on iOS *and* Android wrapped by the umbrella SDKs and the cross-platform plugins?

---

## 1. Summary

**Verdict: feasible but heavy. Recommend Phase 3I in the future, NOT immediately.** MLC LLM is a healthy, Apache-2.0, actively maintained (last commit 2026-04-22) project that gives us an OpenAI-compatible streaming engine on both iOS (Metal) and Android (OpenCL) plus near-trivial Swift / Kotlin APIs that map cleanly onto our existing `*PluginState` shape. The hard part is **distribution**: MLC has no SwiftPM tag, no CocoaPods pod, and no Maven artifact — the canonical workflow is "clone the monorepo, run `mlc_llm package`, statically link the resulting model + runtime libs into your Xcode/Gradle project". Every consumer must run a Python tool against their own model list. Plus models must be pre-compiled per target (`q4f16_1` MLC bundles, not `.gguf`). That makes MLC fundamentally different from every existing dvai-bridge backend, which all install via package manager and read a runtime-supplied model file. We can solve the distribution problem (xcframework + AAR vendoring of pre-built artifacts for a curated model set), but it is a meaningful build-infra investment — comparable to or larger than Phase 3D (Android SDK), with extra ongoing per-model maintenance cost.

---

## 2. What MLC LLM offers today

Source data (all fetched 2026-04-27):

| Property | Value | Source |
|---|---|---|
| GitHub repo | `mlc-ai/mlc-llm` | api.github.com/repos/mlc-ai/mlc-llm |
| License | Apache-2.0 | repo metadata |
| Stars | 22,534 | repo metadata |
| Latest commit | 2026-04-22 (CI migration to GH Actions) | api commits feed |
| Open issues | ~306 | repo metadata |
| Latest tags | `v0.20.dev0`, `v0.19.0` (most recent stable), `v0.18.1`, `v0.17.2`, `v0.17.1` | repo tags |
| TVM dependency | `apache/tvm` (Apache-2.0; pushed 2026-04-27) | api.github.com/repos/apache/tvm |

Activity: 10 commits in the last ~3 weeks (Apr 2 → Apr 22). Recent work includes Qwen3.5 templates, OLMo-2 support, GitHub Actions migration, WebGPU subgroup support. The cadence is "no formal monthly tag, but very active `dev0` rolling tags + roughly quarterly stable releases". Treat MLC like a healthy upstream that we'd pin to a specific commit (same as we already do for some of the iOS llama.cpp xcframeworks).

### 2.1 Supported platforms (per repo README)

> AMD GPU (Vulkan, ROCm) · NVIDIA GPU (Vulkan, CUDA) · Apple GPU (Metal) · Intel GPU (Vulkan) · Web Browser (WebGPU + WASM) · iOS / iPadOS (Metal on Apple A-series) · **Android (OpenCL on Adreno / Mali GPUs)** · Linux / Windows server.

For our purposes: iOS Metal + Android OpenCL.

### 2.2 Runtime engine

The runtime is **TVM Unity** (Apache-2.0), built into a small "MLCEngine" wrapper exposing OpenAI-compatible chat completions. Key files:

- `ios/MLCSwift/Sources/Swift/LLMEngine.swift` (the public Swift `MLCEngine` class — 8 KB)
- `ios/MLCSwift/Sources/Swift/OpenAIProtocol.swift` (request/response Codable types — 9 KB)
- `ios/MLCSwift/Sources/ObjC/LLMEngine.mm` (Objective-C bridge to the C++ JSONFFIEngine — 4 KB)
- `android/mlc4j/src/main/java/ai/mlc/mlcllm/MLCEngine.kt` (the Kotlin counterpart — 6 KB)
- `android/mlc4j/src/main/java/ai/mlc/mlcllm/JSONFFIEngine.java` (JNI bindings — 3 KB)

So the user-facing API is small: ~17 KB of Swift, ~10 KB of Kotlin/Java, on top of a TVM C++ library that's ~tens of MB compiled.

### 2.3 Model format + supported architectures

Models must be **pre-compiled** with the `mlc_llm` Python tool — three steps:

```bash
mlc_llm convert_weight  ./HF/<model>/  --quantization q4f16_1 -o dist/<model>-MLC
mlc_llm gen_config      ./HF/<model>/  --quantization q4f16_1 --conv-template <tpl> -o dist/<model>-MLC
mlc_llm compile         dist/<model>-MLC -o dist/lib/<model>-iphone.tar
```

Output: per-target compiled `.tar`/`.so` ("model lib") + quantized weights bundle.

**Quantizations** in active use (per https://huggingface.co/mlc-ai): `q4f16_1` (4-bit + fp16, default), `q4f32_1`, `q3f16_1`. Approx 400 pre-compiled models in the org, recent additions (last 5 days as of 2026-04-27): `gemma3-1b-it-q4f16_1-MLC`, `Ministral-3-3B-*`, `OLMo-2-1B/7B`, `Qwen3.5-9B`. Llama 3.2 chat space exists.

**Supported model architectures** (from `python/mlc_llm/model/` directory listing): baichuan, bert, chatglm3, cohere, deepseek, deepseek_v2, eagle, gemma, gemma2, gemma3, gpt2, gpt_bigcode, gpt_j, gpt_neox, internlm, internlm2, llama, llama4, **llava**, medusa, minicpm, ministral3, mistral, mixtral, nemotron, olmo, olmo2, orion, phi, phi3, **phi3v**, qwen, qwen2, **qwen2_5_vl**, qwen2_moe, qwen3, qwen35, qwen3_moe, rwkv5, rwkv6, stable_lm, starcoder2, **vision**. Bold = vision/multimodal.

### 2.4 Multimodal status

Vision support exists in the codebase (LLaVA, Phi-3.5-V, Qwen2.5-VL, Qwen3-VL, Llama 4 multimodal) but is **rough on mobile**:
- Issue 2026-03-04 "qwen3-vl segfault" — open
- Issue 2025-12-10 "phi-3.5-vision strange output" — open
- Issue 2024-05-23 "[Model Request] Phi-3-Vision" — open

No documented vision flow on the iOS / Android deploy pages. Treat MLC multimodal on mobile as **best-effort, post-MVP**.

---

## 3. iOS integration plan

### 3.1 Distribution — the hard part

**There is no `Package.swift` consumers can depend on by URL.** `ios/MLCSwift/Package.swift` (fetched directly, 2026-04-27) declares `swift-tools-version:5.5`, no platform minimums, no remote dependencies, and references **local relative C++ header paths**:

```swift
.headerSearchPath("../../tvm_home/include"),
.headerSearchPath("../../tvm_home/3rdparty/tvm-ffi/include"),
.headerSearchPath("../../tvm_home/3rdparty/tvm-ffi/3rdparty/dlpack/include")
```

These paths only resolve relative to a freshly-built `dist/` tree produced by `mlc_llm package`. So the documented integration path (per `docs/deploy/ios.rst`, last updated as of latest commit) is:

1. Consumer clones mlc-llm.
2. Consumer creates `MLCChat/mlc-package-config.json` listing every model they want.
3. Consumer runs `mlc_llm package` (Python, requires Rust + CMake ≥ 3.24 + git-lfs).
4. The script produces `dist/lib/{libmlc_llm.a, libmodel_iphone.a, libsentencepiece.a, libtokenizers_cpp.a, libtvm_runtime.a}` plus `dist/bundle/mlc-app-config.json`.
5. Consumer adds `ios/MLCSwift` as a *local* Swift package, sets a library search path to `dist/lib`, and adds `-Wl,-all_load -lmodel_iphone -lmlc_llm -ltvm_runtime -ltokenizers_cpp -lsentencepiece -ltokenizers_c` to "Other Linker Flags".

This is **incompatible** with how every existing dvai-bridge iOS backend ships:
- `llama-core` ships an xcframework via SwiftPM `binaryTarget`.
- `mlx-core` pulls a Swift package by URL (`mlx-swift-lm`).
- `foundation-core` is system-only.
- `coreml-core` is system-only.

**Two viable options for `ios-mlc-core`:**

**Option A — vendor a curated multi-model xcframework**
We pick a small fixed model set (e.g. Llama-3.2-1B-Instruct-q4f16_1, Phi-3.5-mini-q4f16_1, Gemma-2-2B-q4f16_1), run `mlc_llm package` ourselves on the Mac builder, post-process the output into a single `MLCBridge.xcframework` + a binary blob containing the compiled `model_lib`s, and ship them via SwiftPM `binaryTarget` like `llama-core` does. Consumers pick a model by string id at `start()` time; our package only supports the curated list.
- Mirror script: `scripts/mac-side-prepare-mlc-xcframework.sh` (analog of the existing llama.cpp script).
- Pre-built xcframework size estimate: TVM runtime alone is several MB; with a single q4f16_1 model lib (no weights) ≈ 20-40 MB device-arch slice. Adding 3 model libs ≈ 60-120 MB xcframework. Weights downloaded at runtime from HF.

**Option B — let the consumer run `mlc_llm package` themselves**
We ship `ios-mlc-core` as a thin Swift wrapper that *expects* a sibling `dist/lib` produced by the consumer's own MLC build. Easy to maintain, miserable DX. Rejected for the SDK; possibly fine as an "advanced" escape hatch.

Recommendation: **Option A**, accepting the xcframework size hit and the per-model onboarding cost.

### 3.2 Swift API mapping

The `MLCEngine` Swift class (`ios/MLCSwift/Sources/Swift/LLMEngine.swift`, fetched 2026-04-27) is a near-perfect fit for our `*PluginState` contract:

```swift
// MLC API
let engine = MLCEngine()
await engine.reload(modelPath: "/path/to/weights", modelLib: "llama_3_2_q4f16_1")
for await res in await engine.chat.completions.create(messages: [...]) {
    print(res.choices[0].delta.content!.asText())
}
await engine.unload()
```

- `init()` is sync (just spins up two background threads for the JSON FFI loop).
- `reload(modelPath:modelLib:)` is `async`.
- `chat.completions.create(...)` returns `AsyncStream<ChatCompletionStreamResponse>` — already streaming, already OpenAI-shaped.
- `reset()`, `unload()` — async lifecycle.
- `@available(iOS 14.0.0, *)` — soft minimum is iOS 14 per `LLMEngine.swift`. Match Phase 3C's iOS 17 floor.
- **Stream-only:** `if !stream { logger.error("Only stream=true is supported in MLCSwift") }` — non-stream is unsupported. We'd have to buffer ourselves to support `/v1/chat/completions` without `stream:true`. Same approach we already use for MLX.

### 3.3 PluginState shape

```
packages/dvai-bridge-ios-mlc-core/
├── Package.swift
├── ios/Sources/DVAIMLCCore/
│   ├── MLCPluginState.swift      ~150 lines (mirror MLXPluginState)
│   ├── MLCHandlers.swift         ~150 lines (mirror MLXHandlers — bridge our HTTP route to MLCEngine.chat.completions.create)
│   ├── MLCBackendError.swift     ~40 lines
│   └── Internal/
│       └── MLCModelCatalog.swift ~80 lines (modelId → modelLib resolver for the curated set)
└── ios/Tests/DVAIMLCCoreTests/
    └── MLCPluginStateTest.swift  ~100 lines
```

**LoC estimate:** ~520 lines of Swift, very close to MLX (~261 lines actual today). Slightly bigger because we need a model-id-to-modelLib lookup that mlx doesn't.

### 3.4 Multimodal on iOS

No documented path. The `phi3v`, `qwen2_5_vl`, `llava` model architectures exist, but the OpenAI-compatible streaming Swift API in `LLMEngine.swift` exposes only text `ChatCompletionMessage` — there is no documented vision-content variant. **Defer multimodal to a 3I+1 follow-up.**

### 3.5 Build infra additions

- `scripts/mac-side-prepare-mlc-xcframework.sh` (new) — runs `mlc_llm package` against our curated `mlc-package-config.json`, lipos the per-arch slices, packages an xcframework.
- `scripts/curated-mlc-models.json` (new) — the curated model set.
- Mac-side dependency: Python 3.11 + conda + Rust + CMake ≥ 3.24 + Xcode ≥ 15. Already present on our Mac runner per `docs/development/mac-remote-builds.md`.

### 3.6 Gotchas (iOS)

- **Simulator builds are broken/painful.** Open issue 2024-09-20 "How should I build for iOS Simulator?" (still open). The TVM runtime requires Metal; Simulator on Intel hosts has no GPU. Same operational constraint we already have for MLX. Smoke tests must run on a physical device or `My Mac (designed for iPad)` — same path Phase 3C uses for MLX.
- **Tokenizer build needs Rust.** `ios/MLCSwift` builds the HuggingFace tokenizer via `cargo` at `mlc_llm package` time. Adds Rust to our Mac runner's required toolchain (currently optional).
- **iOS deploy doc is silent on min iOS / Xcode**. The Swift source carries `@available(iOS 14.0.0, *)`; Phase 3C's iOS 17 floor is fine. No Xcode-major lock observed in 2026 issues.

---

## 4. Android integration plan

### 4.1 Distribution — also the hard part

**There is no Maven artifact.** `android/mlc4j/build.gradle` (fetched 2026-04-27):

```groovy
android {
    namespace 'ai.mlc.mlcllm'
    compileSdk 34
    defaultConfig { minSdk 22 }
    sourceSets { main { jniLibs.srcDirs = ['output'] } }
}
dependencies {
    implementation fileTree(dir: 'output', include: ['*.jar'])
    implementation 'androidx.core:core-ktx:1.9.0'
    implementation 'androidx.appcompat:appcompat:1.6.1'
    implementation 'com.google.android.material:material:1.10.0'
    implementation 'org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.3'
}
```

`mlc4j` is a **gradle subproject** that the consumer wires into their `settings.gradle` via:

```groovy
include ':mlc4j'
project(':mlc4j').projectDir = file('dist/lib/mlc4j')
```

Where `dist/lib/mlc4j` is the output of `mlc_llm package`. The subproject's `output/` directory contains:
- `arm64-v8a/libtvm4j_runtime_packed.so` (the heavy native lib — bundles statically-linked TVM + tokenizers + per-model `libmodel_android.a` via `-Wl,--whole-archive`)
- `tvm4j_core.jar` (~60 KB Java binding to TVM, per Apache TVM JVM bindings)

**ABIs.** The deploy doc and `CMakeLists.txt` show **arm64-v8a only**. The demo APK is built for "Samsung S23 with Snapdragon 8 Gen 2". The CMakeLists' `install` line is `install(TARGETS tvm4j_runtime_packed LIBRARY DESTINATION output/${ANDROID_ABI})`, so x86_64 is buildable in principle but no tested distribution. **Phone-only, arm64-v8a-only is the practical floor.**

**NDK requirement.** Per the deploy doc:
> "The current demo Android APK is built with NDK 27.0.11718014. Please update your NDK to avoid build android package fail (#2696)."

Our `android-llama-core` and `android-mediapipe-core` are currently NDK-version-agnostic. Phase 3I would need to pin NDK ≥ 27 in the umbrella consumer.

**Min/target SDK.** `compileSdk 34`, `minSdk 22`. Our existing cores have similar minimums.

**Two viable options for `android-mlc-core`** (mirror iOS):

**Option A — vendor a pre-built AAR with a curated model set.**
We run `mlc_llm package` on a CI runner against our curated `mlc-package-config.json`, take the resulting `dist/lib/mlc4j` source tree, build it ourselves into an AAR (the `tvm4j_runtime_packed.so` per ABI + the `tvm4j_core.jar` source-baked into the AAR), then publish to GitHub Packages Maven the same way Phase 3D ships `co.deepvoiceai:dvai-bridge`. Result: a normal `implementation("co.deepvoiceai:android-mlc-core:2.x.y")` line, no consumer-side Python or Rust. AAR weight: ~30-100 MB depending on how many model libs we statically link in.

**Option B — keep the source-build flow.** Document `mlc_llm package` as a prerequisite. Same DX problem as iOS Option B.

Recommendation: **Option A** for parity with our other Android cores.

### 4.2 Kotlin API mapping

`android/mlc4j/src/main/java/ai/mlc/mlcllm/MLCEngine.kt` (fetched 2026-04-27):

```kotlin
val engine = MLCEngine()
engine.reload(modelPath = "/path/to/weights", modelLib = "phi_3_5_mini_q4f16_1")
val channel: ReceiveChannel<ChatCompletionStreamResponse> = engine.chat.completions.create(messages = [...])
for (res in channel) {
    println(res.choices[0].delta.content?.asText())
}
engine.unload()
```

- `init` spawns two background threads (matches the iOS shape).
- `reload(modelPath, modelLib)` is sync (no `suspend`).
- `chat.completions.create(...)` is `suspend`, returns `ReceiveChannel<ChatCompletionStreamResponse>` — channel-based streaming, different shape from MediaPipe's `MessageCallback` but easy to adapt to our HTTP SSE writer.
- **Stream-only**: `if (!stream) throw IllegalArgumentException("Only stream=true is supported in MLCKotlin")`.
- `reset()`, `unload()` — both sync.
- Uses `kotlinx-serialization-json:1.6.3` — already in our Android dependency graph.

### 4.3 PluginState shape

```
packages/dvai-bridge-android-mlc-core/
├── android/build.gradle.kts
├── android/src/main/java/co/deepvoiceai/bridge/mlc/core/
│   ├── MLCPluginState.kt        ~180 lines (mirror MediaPipe's PluginState)
│   ├── MLCHandlers.kt           ~280 lines (mirror MediaPipeHandlers — bridge HTTP route to engine.chat.completions.create)
│   ├── MLCBackendError.kt       ~30 lines
│   └── Internal/
│       └── MLCModelCatalog.kt   ~100 lines
└── android/src/test/java/co/deepvoiceai/bridge/mlc/core/
    └── MLCPluginStateTest.kt    ~120 lines
```

**LoC estimate:** ~700 lines of Kotlin. Smaller than `litert-core` (~1387 lines, has its own sampler + manual HF tokenizer JNI) and slightly smaller than `mediapipe-core` (~934 lines) because MLC's `MLCEngine` does the tokenization, sampling, and OpenAI shaping for us.

### 4.4 GPU / runtime details

- GPU: **OpenCL on Adreno / Mali**. No Vulkan path on Android (Vulkan is desktop-only per the README). No CPU fallback documented for mobile.
- The runtime requires "an actual mobile GPU" per the deploy doc — emulators don't work. Same operational constraint as Phase 3D's instrumented tests, which already require physical devices for MediaPipe.
- Known issue (per deploy doc): models with `_1` weight-layout suffix cause a 20-50 sec UI freeze at prefill on Adreno GPUs. Workaround: prefer `_0` quantizations. The `mlc-ai` HF org currently ships almost exclusively `_1` variants — we'd have to recompile `_0` ourselves or accept the freeze, **needs verification before committing**.

### 4.5 Multimodal on Android

No documented path on the Android deploy page. Same defer-to-followup conclusion as iOS.

### 4.6 Gotchas (Android)

- **NDK 27+ pinned.** Our existing cores are NDK-agnostic; this becomes a hard constraint on the umbrella when MLC is selected.
- **arm64-v8a only.** No 32-bit, no x86_64 emulator support out-of-the-box.
- **Symbol collisions:** `tvm4j_runtime_packed.so` statically links `mlc_llm_static`, `tokenizers_c`, `tokenizers_cpp`, plus the per-model `libmodel_android.a`. If a consumer also pulls `android-llama-core` (which carries its own `libllama.so`) symbols are isolated per `.so` so collisions are unlikely, but the `tokenizers_cpp` static link could in principle conflict with another HF-tokenizer-using `.so`. Worth a dedicated check during 3I implementation.
- **Rust + Python prerequisites only on the build runner**, not the consumer (Option A removes that pain). Bumps our CI image fat though.

---

## 5. Cross-platform consequences

### 5.1 Capacitor

A new `@dvai-bridge/capacitor-mlc` package is needed (cannot piggy-back on `capacitor-llama` or `capacitor-mlx` because those wrap a single backend each, per the existing `packages/dvai-bridge-capacitor-*` layout). Estimated effort: ~300 lines of TS shim + iOS plugin glue + Android plugin glue, mirroring `capacitor-mlx`. The JS-side `BackendKind` union grows to include `"mlc"`.

### 5.2 React Native

Per Phase 3E's design, `BackendKind` is a string union in TS. Adding `"mlc"` is a one-line change in `packages/dvai-bridge-react-native/src/types.ts` plus the equivalent TurboModule enum case on each native side. **Free change**, no native work in 3E itself.

### 5.3 Flutter (Phase 3F, owned by another agent — DO NOT TOUCH)

Pigeon enum in 3F's design carries `BackendKind`. Adding `mlc` is similarly a one-line change once 3F lands. Coordinate after 3F's main commits are in.

### 5.4 Umbrella SDKs

- iOS `BackendKind.swift`: add `case mlc` (mirror the `mlx` doc-comment shape — Apple-Silicon only, SwiftPM-only). One-line change + dispatch case in `DVAIBridge.start()`.
- Android `BackendKind.kt`: add `MLC` value + dispatch.
- Backend selectors: extend `BackendSelector.resolve()` on both platforms — a `modelPath` ending in `mlc-app-config.json` or matching `HF://mlc-ai/...` would map to `MLC`. Trivial.

---

## 6. Open questions / gotchas summary

| # | Question | Why it matters | Notes |
|---|---|---|---|
| 1 | Are we OK with curated-model lock-in? | Option A means consumers can only use the 3-5 models we pre-compile. Adding a new model = new package release. | Phase 3D's LiteRT lets consumers BYO `.tflite`; this is a regression in flexibility. |
| 2 | Adreno `_1` quantization freeze | Recompiling everything as `_0` doubles our packaging cost. | Verify on a real Adreno device before committing to a curated set. |
| 3 | xcframework size | 3-model bundle ≈ 60-120 MB. Triples our SDK download size if consumers add `mlc-core` alongside `llama-core`. | Mitigation: ship per-model sub-packages. |
| 4 | Tokenizer-cpp symbol collision | If a future Android backend also embeds `tokenizers_cpp` statically, we may get duplicate-symbol issues at consumer link time. | Low risk today; document the constraint. |
| 5 | Vision support timeline | LLaVA / Phi-3.5-V / Qwen2.5-VL models exist in `python/mlc_llm/model/` but no documented mobile path. | Multimodal parity = follow-up phase. |
| 6 | Stream-only API | Both Swift and Kotlin engines refuse `stream:false`. | We already buffer for MLX; reuse the same approach. |
| 7 | iOS Simulator | Same constraint as MLX. | Smoke tests gated on physical device or "My Mac (designed for iPad)". |
| 8 | NDK 27 pin on Android | New requirement for the umbrella when MLC is in scope. | Bump existing cores' tested NDK to 27 for parity. |
| 9 | License / weight redistribution | We'd be hosting per-target compiled model libs. Llama 3.x, Gemma weights have specific licenses. | Defer to legal-review checkpoint inside the spec. |
| 10 | Maintenance cadence | MLC moves fast; recompiling our curated set on every TVM bump is a chore. | Could be a recurring CI job, not a release-gate. |
| 11 | Does TVM expose the model lib as `.so` or `.a`? | We saw both `libmodel_iphone.a` (static, iOS) and `libmodel_android.a` (static, Android). Both go into a single packed `.so` on Android via `--whole-archive`. | Determines whether multi-model = multi-AAR or single-AAR-with-N-libs. |

---

## 7. Recommended next step

**Recommendation: SCHEDULE a Phase 3I spec, but DO NOT start it before Phase 3F (Flutter) and Phase 3H (publish/launch) are green.** Rationale:

1. The integration is feasible and the API surface is the cleanest of any third-party LLM runtime we've evaluated (cleaner than MLX, much cleaner than LiteRT). MLCEngine is an OpenAI-shaped streaming engine out of the box. **API-side LoC is ~520 Swift / ~700 Kotlin** — comfortable.
2. The distribution + build-infra side is a meaningful new investment (curated xcframework + curated AAR + new mac-side script + Rust/Python in CI + per-model HF coordination). **Estimate: ~1.3-1.5× the Phase 3D effort** (which delivered Android SDK + LiteRT core + shared-core extraction). The Android SDK landed in ~3 weeks of focused work, so plan ~4-5 weeks for 3I.
3. Marginal value vs. existing backends:
   - On iOS, MLX already covers Apple-Silicon GPU LLM with HF model loading. MLC's iOS edge is "non-Apple-Silicon" (older iPhones), but those devices have insufficient memory for any modern LLM anyway.
   - On Android, MediaPipe + LiteRT cover the same ground for `.task` / `.tflite` / `.litertlm` users. MLC's Android edge is "Adreno/Mali GPU acceleration with OpenCL", which is **genuinely new** — neither MediaPipe nor LiteRT exposes raw OpenCL today.
4. The Adreno/Mali OpenCL story is the one strategic reason to do this. If perf measurements show MLC ≥ 2× faster than MediaPipe on Snapdragon-class devices (an unverified hypothesis from MLC's own benchmarks), 3I is worth the cost. If perf is comparable, defer indefinitely.

**Concrete next-step deliverable when we are ready:** a Phase 3I design doc in the same shape as `2026-04-27-phase3d-android-native-sdk-design.md`, scoped to:
- One curated model set (4 models max: Llama-3.2-1B, Phi-3.5-mini, Gemma-2-2B, Qwen2.5-1.5B — all `q4f16_1` `_0`-layout if Adreno freeze confirmed).
- Two new `*-core` packages (`ios-mlc-core`, `android-mlc-core`) + one new Capacitor wrapper.
- Mac-side `prepare-mlc-xcframework.sh` script + Linux-side `prepare-mlc-aar.sh`.
- One-week perf-spike preceding the spec to validate the OpenCL-perf hypothesis on a Pixel 8 Pro and Samsung S24.

**Block before starting:** confirm the perf hypothesis. Without that data, MLC is a parallel third path that adds maintenance burden without clear differentiation.

---

## 8. References

All URLs fetched 2026-04-27.

- MLC LLM repository: https://github.com/mlc-ai/mlc-llm
- iOS deploy doc: https://llm.mlc.ai/docs/deploy/ios.html (raw: https://raw.githubusercontent.com/mlc-ai/mlc-llm/main/docs/deploy/ios.rst)
- Android deploy doc: https://llm.mlc.ai/docs/deploy/android.html (raw: https://raw.githubusercontent.com/mlc-ai/mlc-llm/main/docs/deploy/android.rst)
- MLCSwift Package.swift: https://raw.githubusercontent.com/mlc-ai/mlc-llm/main/ios/MLCSwift/Package.swift
- iOS `MLCEngine.swift` source: https://raw.githubusercontent.com/mlc-ai/mlc-llm/main/ios/MLCSwift/Sources/Swift/LLMEngine.swift
- Android `mlc4j/build.gradle`: https://raw.githubusercontent.com/mlc-ai/mlc-llm/main/android/mlc4j/build.gradle
- Android `mlc4j/CMakeLists.txt`: https://raw.githubusercontent.com/mlc-ai/mlc-llm/main/android/mlc4j/CMakeLists.txt
- Android `MLCEngine.kt` source: https://raw.githubusercontent.com/mlc-ai/mlc-llm/main/android/mlc4j/src/main/java/ai/mlc/mlcllm/MLCEngine.kt
- MLC HuggingFace org: https://huggingface.co/mlc-ai
- Apache TVM repository (license check): https://api.github.com/repos/apache/tvm
- Repo metadata API (stars, license, pushed_at): https://api.github.com/repos/mlc-ai/mlc-llm
- Recent commits: https://api.github.com/repos/mlc-ai/mlc-llm/commits
- Tags: https://api.github.com/repos/mlc-ai/mlc-llm/tags
- Vision-related issues: https://api.github.com/search/issues?q=repo:mlc-ai/mlc-llm+vision+is:issue
- Xcode-related issues: https://api.github.com/search/issues?q=repo:mlc-ai/mlc-llm+xcode+is:issue
- Supported model architectures: https://api.github.com/repos/mlc-ai/mlc-llm/contents/python/mlc_llm/model
- Phase 3D spec (the closest analog for sizing): `docs/superpowers/specs/2026-04-27-phase3d-android-native-sdk-design.md`
- iOS MLX core (the closest analog for iOS LoC sizing): `packages/dvai-bridge-ios-mlx-core/`
- Android MediaPipe core (the closest analog for Android LoC sizing): `packages/dvai-bridge-android-mediapipe-core/`
