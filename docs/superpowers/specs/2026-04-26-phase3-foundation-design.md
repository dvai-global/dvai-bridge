# Phase 3 — Native SDKs Foundation (3A + 3B Design)

**Status:** Draft — awaiting review
**Date:** 2026-04-26
**Scope:** Phase 3A (core extraction across all capacitor-* plugins) + Phase 3B (MediaPipe → LiteRT-LM migration). These two land before any standalone native SDK work (3C iOS, 3D Android, 3E RN, 3F Flutter, 3G .NET, 3H docs/release).
**Phase 3 launch dependency:** 3A + 3B are the load-bearing structural work for every downstream native SDK in Phase 3.

---

## 1. Phase 3 — overall context

After Phase 2, dvai-bridge ships native HTTP-server-embedded backends on iOS + Android via three Capacitor plugins (`capacitor-llama`, `capacitor-foundation`, `capacitor-mediapipe`). Phase 3 productizes the same native code as **standalone SDKs** for non-Capacitor consumers — iOS Swift Package Manager, Android AAR, .NET NuGet — plus cross-framework wrappers for React Native and Flutter that consume those native SDKs.

The README's platform matrix already promises seven platform/language stacks. Phase 3 fills in the four bottom rows that don't have shipping packages yet.

| Stack | Status going into Phase 3 |
|---|---|
| Browser (`@dvai-bridge/core` + React/Vanilla) | ✅ shipping |
| Node / Bun (`@dvai-bridge/core` HTTP transport) | ✅ shipping |
| Electron main (uses `@dvai-bridge/core`) | ✅ shipping (Transformers.js + WebLLM; native NAPI llama.cpp not built) |
| Capacitor mobile | ✅ shipping (post Phase 1+2 merge) |
| **Android native (AAR)** | ❌ |
| **iOS native (SPM)** | ❌ |
| **.NET desktop (NuGet)** | ❌ |
| **React Native module** | ❌ |
| **Flutter package** | ❌ |

### 1.1 Sub-phase map (full Phase 3, with 3A + 3B as foundation)

| Sub-phase | Scope | Risk | Depends on |
|---|---|---|---|
| **3A** | Core extraction — split each capacitor-* plugin into `*-core` (no Capacitor) + `capacitor-*` (thin wrapper) | Low | — |
| **3B** | MediaPipe → LiteRT-LM SDK migration in the new `android-mediapipe-core` package | Med-High | 3A |
| 3C | iOS native SDK (`DVAIBridge` SPM package) — wraps `ios-llama-core` + `ios-foundation-core` + adds CoreML backend | Low-Med | 3A |
| 3D | Android native SDK (`co.deepvoiceai:dvai-bridge` AAR) — wraps `android-llama-core` + `android-mediapipe-core` (post-3B) + adds LiteRT backend | Med | 3A, 3B |
| 3E | React Native module — wraps 3C + 3D, full surface incl. reactive getters | Low | 3C, 3D |
| 3F | Flutter package — wraps 3C + 3D | Low | 3C, 3D |
| 3G | .NET NuGet — greenfield: llama.cpp shared lib + ONNX Runtime GenAI + DirectML, with first-party LLM-runtime IP layered on top of ML.NET | High | 3A (pattern only) |
| 3H | Multi-publish automation, docs, RESEARCH.md SVG updates, marketing scripts (private), release prep | Low | All above |

3A + 3B are the foundation. After they land, 3C–3F become mostly extraction + wrapping with low marginal risk; 3G is a fully independent track.

### 1.2 Why 3A + 3B together (one design doc)

3B (MediaPipe → LiteRT-LM) is a substantial code rewrite of the MediaPipe Android backend. Doing it before 3A means rewriting code in `capacitor-mediapipe` only to immediately move that code in 3A. Doing it after 3A means rewriting the freshly-extracted `android-mediapipe-core` package — same work, no double-touch.

So: 3A first (mechanical refactor, low risk), 3B second (substantive rewrite in the right place, isolated to one package).

---

## 2. Goals (3A + 3B)

### Goals — Phase 3A

1. Every Capacitor plugin's portable code lives in a separate `*-core` package that has zero Capacitor dependencies.
2. Each `capacitor-*` package becomes a thin wrapper that imports the corresponding `*-core` package(s) and adds only the Capacitor-specific lifecycle plumbing (`@CapacitorPlugin` annotation on Android, `CAPPlugin` subclass on iOS, JS plugin registration).
3. The native code is **one source of truth**: any future change to `HttpServer`, `LlamaHandlers`, `PluginState`, `ContentPartsTranslator`, `ModelDownloader`, decoders, or bridges happens in exactly one place and flows through to both the Capacitor plugin and (later) the native SDK.
4. All existing tests pass after the refactor — TS suite (104), iOS XCTest (llama 65 + foundation 11 + mediapipe), Android JVM (capacitor-llama + capacitor-mediapipe). No coverage loss.
5. Native libraries built by the new `*-core` packages are 16 KB-page-size aligned per Google's 2025 mandate (cross-cutting Android requirement; verified in CI).

### Goals — Phase 3B

1. Replace the deprecated `com.google.mediapipe:tasks-genai:0.10.33` and `tasks-core:0.10.33` dependencies with Google's LiteRT-LM SDK in the freshly-extracted `android-mediapipe-core` package.
2. Preserve the existing `MediaPipeBridge` interface so `MediaPipeHandlers` and the Capacitor wrapper are untouched (parity test with the existing 24+ JVM tests is the success criterion).
3. Where LiteRT-LM exposes capabilities the older API didn't (e.g. better quantization options, LoRA, audio modality) — document them but don't expose new API surface in 3B; future sub-phases can add features on top of the migration.

### Non-goals (3A + 3B)

- New public API surface (postponed to 3C-3G).
- New backends like CoreML or LiteRT (those are 3C and 3D respectively).
- Performance optimization — measure but don't tune; 3A is structural, 3B is API replacement.
- Distribution / publishing setup (postponed to 3H).
- Renaming any types, methods, or modules visible to existing users of the Capacitor plugins.
- Bumping llama.cpp's pinned upstream SHA (separate work, has its own commit cadence).
- Anything related to CoreML, ONNX Runtime GenAI, .NET, RN, or Flutter (those sub-phases own that).

---

## 3. Phase 3A — Core extraction architecture

### 3.1 Why "core" packages

The current code is already 90% portable. Inspecting `packages/dvai-bridge-capacitor-llama/`:

- `ios/Sources/DVAICapacitorLlama/Plugin.swift` is the only file importing `Capacitor`.
- `ios/Sources/DVAICapacitorLlama/PluginProxy.m` is a Capacitor-specific ObjC bridge.
- Everything under `ios/Sources/DVAICapacitorLlama/Internal/` (HttpServer, HandlerDispatch, LlamaHandlers, ContentPartsTranslator, PluginState, ModelDownloader, ImageDecoder, AudioDecoder, LlamaCppBridgeProtocol) is pure Swift with no Capacitor coupling.
- `ios/Sources/DVAICapacitorLlamaObjC/` (LlamaCppBridge.mm + headers) is ObjC++ wrapping llama.cpp, also Capacitor-free.

Same pattern on Android: `Plugin.kt` carries `@CapacitorPlugin`; `PluginState.kt`, `HttpServer.kt`, `HandlerDispatch.kt`, `LlamaHandlers.kt`, `ContentPartsTranslator.kt`, `ImageDecoder.kt`, `AudioDecoder.kt`, `ModelDownloader.kt`, `LlamaCppBridge.kt` are pure Kotlin/JNI.

Phase 3A formalizes that separation by physically moving the portable files into separate packages. The Capacitor packages then declare a dependency on the new core packages.

### 3.2 New package layout

```
packages/
├── dvai-bridge-core/                       # existing TS — unchanged
├── dvai-bridge-react/                      # existing TS — unchanged
├── dvai-bridge-vanilla/                    # existing TS — unchanged
├── dvai-bridge-capacitor/                  # existing TS routing shim — unchanged
│
├── dvai-bridge-ios-llama-core/             # NEW — pure Swift llama core (no Capacitor)
├── dvai-bridge-ios-foundation-core/        # NEW — pure Swift Foundation Models core (no Capacitor)
├── dvai-bridge-android-llama-core/         # NEW — pure Kotlin/JNI llama core (no Capacitor)
├── dvai-bridge-android-mediapipe-core/     # NEW — pure Kotlin MediaPipe core (no Capacitor) [3B target]
│
├── dvai-bridge-capacitor-llama/            # REFACTORED — depends on ios-llama-core + android-llama-core
├── dvai-bridge-capacitor-foundation/       # REFACTORED — depends on ios-foundation-core
└── dvai-bridge-capacitor-mediapipe/        # REFACTORED — depends on android-mediapipe-core
```

**8 new directories** under `packages/` (4 new core packages, 4 existing capacitor-* refactored). The four pure-TS packages and the routing shim are untouched.

### 3.3 iOS package structure (per *-core package)

Each iOS core package follows this layout:

```
packages/dvai-bridge-ios-llama-core/
├── package.json                             # npm package metadata (so monorepo tooling works)
├── ios/
│   ├── Package.swift                        # SPM manifest
│   └── Sources/
│       ├── DVAILlamaCore/                   # pure Swift core — was ios/Sources/DVAICapacitorLlama/Internal/
│       │   ├── HttpServer.swift
│       │   ├── HandlerContext.swift
│       │   ├── HandlerDispatch.swift
│       │   ├── LlamaHandlers.swift
│       │   ├── ContentPartsTranslator.swift
│       │   ├── PluginState.swift
│       │   ├── ModelDownloader.swift
│       │   ├── ImageDecoder.swift
│       │   ├── AudioDecoder.swift
│       │   └── LlamaCppBridgeProtocol.swift
│       └── DVAILlamaCoreObjC/               # ObjC++ — was ios/Sources/DVAICapacitorLlamaObjC/
│           ├── include/
│           │   └── LlamaCppBridge.h
│           └── LlamaCppBridge.mm
└── Tests/                                   # iOS Swift tests, moved from capacitor-llama
    └── DVAILlamaCoreTests/
        ├── HttpServerTest.swift
        ├── LlamaHandlersTest.swift
        ├── ContentPartsTranslatorTest.swift
        ├── PluginStateTest.swift
        ├── ModelDownloaderTest.swift
        ├── ImageDecoderTest.swift
        ├── AudioDecoderTest.swift
        ├── LlamaCppBridgeTest.swift
        └── (RealModelSmokeTest stays — see §3.7)
```

**Type-renaming policy:** the Swift module is `DVAILlamaCore` (was `DVAICapacitorLlama`), but **public type names inside it are unchanged** — `PluginState`, `HttpServer`, `LlamaHandlers`, `LlamaCppBridge`, `LlamaCppBridgeProtocol`, etc. all keep the same Swift names. Existing Swift code in the Capacitor wrapper just changes its `import` line; no rewrites of type references.

Within Swift's name resolution, `DVAILlamaCore.PluginState` is now the canonical reference; the old `DVAICapacitorLlama.PluginState` no longer exists (the wrapper module exports a different smaller surface).

The ObjC++ submodule rename (`DVAICapacitorLlamaObjC` → `DVAILlamaCoreObjC`) is similar — the C symbol name `LlamaCppBridge` (the ObjC class) stays unchanged; only the SPM target name changes.

### 3.4 Refactored Capacitor iOS package

```
packages/dvai-bridge-capacitor-llama/
├── package.json                             # unchanged metadata + new peer-dep on ios-llama-core's npm package
├── ios/
│   ├── Package.swift                        # depends on dvai-bridge-ios-llama-core's Package
│   └── Sources/
│       └── DVAICapacitorLlama/              # only Capacitor-specific files now
│           ├── Plugin.swift                 # @objc(DVAIBridgeLlamaPlugin) class — wraps PluginState
│           └── PluginProxy.m                # Capacitor's ObjC plugin macro
└── Tests/                                   # only the smoke test stays here — see §3.7
    └── DVAICapacitorLlamaTests/
        └── RealModelSmokeTest.swift
```

`Plugin.swift` after refactor (illustrative — actual file is small):

```swift
import Capacitor
import DVAILlamaCore  // <-- new import; was previously @testable from same module

@objc(DVAIBridgeLlamaPlugin)
public class DVAIBridgeLlamaPlugin: CAPPlugin {
    private let state = PluginState()

    @objc func start(_ call: CAPPluginCall) {
        Task {
            do {
                let result = try await state.start(opts: call.options ?? [:])
                call.resolve(result)
            } catch {
                call.reject(error.localizedDescription)
            }
        }
    }
    // ... stop, status, downloadModel, listCachedModels, deleteCachedModel, cacheDir
    // (all delegate to PluginState / ModelDownloader from DVAILlamaCore)
}
```

### 3.5 Android package structure (per *-core package)

Each Android core package follows this layout:

```
packages/dvai-bridge-android-llama-core/
├── package.json                             # npm metadata (monorepo tooling)
├── android/
│   ├── build.gradle                         # standalone com.android.library; NDK + JNI for llama
│   ├── settings.gradle
│   ├── gradlew / gradlew.bat / gradle/
│   └── src/
│       ├── main/
│       │   ├── AndroidManifest.xml          # bare; no Capacitor merge
│       │   ├── cpp/                         # JNI bridge — was capacitor-llama/android/src/main/cpp/
│       │   │   ├── jni-bridge.cpp
│       │   │   └── CMakeLists.txt
│       │   └── java/co/deepvoiceai/dvaibridge/llama/core/
│       │       ├── HttpServer.kt
│       │       ├── HandlerDispatch.kt
│       │       ├── LlamaHandlers.kt
│       │       ├── ContentPartsTranslator.kt
│       │       ├── PluginState.kt
│       │       ├── ModelDownloader.kt
│       │       ├── ImageDecoder.kt
│       │       ├── AudioDecoder.kt
│       │       └── LlamaCppBridge.kt
│       ├── test/                            # JVM tests moved from capacitor-llama
│       └── androidTest/                     # instrumented tests, including RealModelSmokeTest
└── (no native llama.cpp submodule — that stays in capacitor-llama for now and is consumed via NDK source path)
```

**Package rename:** Kotlin source moves from `co.deepvoiceai.dvaibridge.llama` to `co.deepvoiceai.dvaibridge.llama.core`. The class names (`HttpServer`, `LlamaHandlers`, `PluginState`, etc.) are unchanged. Existing imports in the Capacitor wrapper update to the new package.

The llama.cpp submodule and the NDK build live in the core package now. The Capacitor wrapper has no native code path of its own.

### 3.6 Refactored Capacitor Android package

```
packages/dvai-bridge-capacitor-llama/
├── android/
│   ├── build.gradle                         # depends on android-llama-core via project path
│   ├── settings.gradle                      # includes android-llama-core
│   └── src/main/
│       ├── AndroidManifest.xml              # NSC + cleartext loopback rules
│       └── java/co/deepvoiceai/dvaibridge/llama/
│           └── Plugin.kt                    # @CapacitorPlugin — wraps core's PluginState
```

`build.gradle` (illustrative):

```gradle
dependencies {
    api project(":dvai-bridge-android-llama-core")     // re-export core's API to consumers
    implementation "com.getcapacitor:capacitor-android:$capacitorVersion"
    // ... existing deps
}
```

`settings.gradle`:

```gradle
include ':dvai-bridge-android-llama-core'
project(':dvai-bridge-android-llama-core').projectDir = file('../../dvai-bridge-android-llama-core/android')
```

This makes the core a project-relative Gradle module rather than a published artifact. Capacitor's `cap sync` mechanism walks the package's android/ folder and includes referenced project paths if they're under `node_modules` — so the core package needs to be syncable too.

### 3.7 Source reuse without double-publishing — the `cap sync` constraint

Capacitor consumes plugins via npm. The host app installs `@dvai-bridge/capacitor-llama`, runs `npx cap sync`, and Capacitor copies `node_modules/@dvai-bridge/capacitor-llama/{ios,android}/` into the host app's iOS / Android project tree.

For the core package's source to flow through, two options:

**Option A: Core package is also npm-installed by the host app.**
- Host app declares both `@dvai-bridge/capacitor-llama` and `@dvai-bridge/ios-llama-core` (or `android-llama-core`) as dependencies. The capacitor package's `package.json` declares the core as a `peerDependency`.
- `cap sync` copies both packages' platform folders. The Capacitor wrapper's `Package.swift` / `build.gradle` references the core's relative path within `node_modules`.
- Pro: clean separation; core is a real npm package usable independently.
- Con: host app installs two npm packages for one plugin.

**Option B: Capacitor wrapper bundles the core's source via cap-sync hooks.**
- The capacitor package's npm `prepublish` step copies `dvai-bridge-ios-llama-core/ios/Sources/` into its own `ios/Sources/` so the published tarball is self-contained.
- Pro: host app only installs the Capacitor package.
- Con: the core source is duplicated at publish time; risk of stale published copies; CI must verify sync.

**Decision: Option A.** Cleaner, no publish-time duplication, and the core package is the canonical npm location for native-SDK consumers in 3C+ anyway. The "two npm packages" cost is minor and discoverable via the Capacitor plugin's documented install command (`npm install @dvai-bridge/capacitor-llama @dvai-bridge/ios-llama-core @dvai-bridge/android-llama-core`).

The plugin's npm package's README documents the install command. The Capacitor JS shim already wraps "plugin not installed" into an actionable error; we extend that to mention missing core packages too.

### 3.8 Test relocation

Tests follow the code they exercise.

| Test file | Current location | New location |
|---|---|---|
| HttpServerTest.swift | `capacitor-llama/ios/Tests/` | `ios-llama-core/Tests/DVAILlamaCoreTests/` |
| HandlerDispatchTest.swift | `capacitor-llama/ios/Tests/` | `ios-llama-core/Tests/DVAILlamaCoreTests/` |
| LlamaHandlersTest.swift | `capacitor-llama/ios/Tests/` | `ios-llama-core/Tests/DVAILlamaCoreTests/` |
| ContentPartsTranslatorTest.swift | `capacitor-llama/ios/Tests/` | `ios-llama-core/Tests/DVAILlamaCoreTests/` |
| PluginStateTest.swift | `capacitor-llama/ios/Tests/` | `ios-llama-core/Tests/DVAILlamaCoreTests/` |
| ModelDownloaderTest.swift | `capacitor-llama/ios/Tests/` | `ios-llama-core/Tests/DVAILlamaCoreTests/` |
| ImageDecoderTest.swift | `capacitor-llama/ios/Tests/` | `ios-llama-core/Tests/DVAILlamaCoreTests/` |
| AudioDecoderTest.swift | `capacitor-llama/ios/Tests/` | `ios-llama-core/Tests/DVAILlamaCoreTests/` |
| LlamaCppBridgeTest.swift | `capacitor-llama/ios/Tests/` | `ios-llama-core/Tests/DVAILlamaCoreTests/` |
| SmokeTest.swift (sanity-only) | `capacitor-llama/ios/Tests/` | `capacitor-llama/ios/Tests/DVAICapacitorLlamaTests/` (stays — exercises the Capacitor wrapper) |
| RealModelSmokeTest.swift | `capacitor-llama/ios/Tests/` | `capacitor-llama/ios/Tests/DVAICapacitorLlamaTests/` (stays — end-to-end with smoke env) |

Same pattern on Android: JVM unit tests under `src/test/` follow the source they cover; instrumented tests including `RealModelSmokeTest.kt` stay with the Capacitor wrapper or move to the core depending on whether they exercise Capacitor's lifecycle plumbing.

**Why the smoke test stays with the Capacitor wrapper:** `RealModelSmokeTest` tests the Capacitor plugin's `start() / stop()` API as a black box; it exercises the Capacitor wrapper plus the core. Moving it to the core would change its scope.

### 3.9 Capacitor JS shim — unchanged

`@dvai-bridge/capacitor` (the routing shim) doesn't move. Its public API is what host apps import; renaming or splitting it would be a breaking change for Capacitor consumers — out of scope for 3A.

The shim's internal dispatch already routes by backend ID (`DVAIBridgeLlama`, `DVAIBridgeFoundation`, `DVAIBridgeMediaPipe`); those plugin IDs are owned by the Capacitor wrapper packages, not the core packages. Refactoring under those IDs is internal.

---

## 4. Phase 3B — MediaPipe → LiteRT-LM migration

### 4.1 Why migrate

`com.google.mediapipe:tasks-genai:0.10.x` is marked `@Deprecated` since 0.10.27. Google's recommended successor is the **LiteRT-LM** SDK (formerly known as "Mediapipe LLM Inference, LiteRT edition"), distributed as `com.google.ai.edge.litert.lm:litert-lm` (or similar — exact artifact ID inventoried in 3B Task 1). LiteRT-LM is the same underlying inference runtime exposed under a redesigned, non-deprecated API surface.

Phase 3B migrates `android-mediapipe-core` (the package created in 3A) to LiteRT-LM. The capacitor-mediapipe wrapper is untouched because the bridge interface stays the same.

### 4.2 Current MediaPipe API surface (what gets migrated)

Per inspection of `MediaPipeBridge.kt`:

```kotlin
// Imports — all from com.google.mediapipe.*
import com.google.mediapipe.framework.image.MPImage
import com.google.mediapipe.tasks.genai.llminference.GraphOptions
import com.google.mediapipe.tasks.genai.llminference.LlmInference
import com.google.mediapipe.tasks.genai.llminference.LlmInferenceSession

// Concrete usage
LlmInference.LlmInferenceOptions.builder()
    .setModelPath(modelPath)
    .setMaxTopK(...)
    .setPreferredBackend(LlmInference.Backend.GPU)
    .setMaxNumImages(...)             // vision
    .build()
LlmInference.createFromOptions(context, options)

LlmInferenceSession.LlmInferenceSessionOptions.builder()
    .setTopK(...)
    .setTemperature(...)
    .setGraphOptions(GraphOptions.builder().setEnableVisionModality(true).build())
    .build()
LlmInferenceSession.createFromOptions(engine, sessionOptions)

// Inference
session.addQueryChunk(prompt)
session.addImage(MPImage)              // vision
session.generateResponse()             // synchronous
session.generateResponseAsync(progressListener)  // streaming via listener
```

### 4.3 Target LiteRT-LM API surface

**To be inventoried in Task 3B-1.** Google's LiteRT-LM 1.x ships with a redesigned API; Task 3B-1 reads the official API reference and produces a side-by-side mapping doc. The migration tasks in 3B then implement that mapping.

Provisional expectations based on Google's broader `ai.edge` package conventions:

- Engine + session pattern likely preserved (one engine per model, multiple sessions per engine).
- `MPImage` likely replaced with a LiteRT-LM-specific image type or a `Bitmap` directly.
- `GraphOptions` likely subsumed into a different options class.
- Streaming likely via Kotlin `Flow<String>` or callback parity with Coroutines.

**Risk if the API substantially differs:** the `MediaPipeBridge` interface that `MediaPipeHandlers` depends on is internal; we can preserve the interface signatures while changing the implementation freely. The only public-facing surface is the Capacitor plugin's `start() / stop()` JSON contract, which doesn't expose any MediaPipe-specific types.

### 4.4 Migration approach — two-pass

**Pass A: Inventory + pure-replacement.** Update `build.gradle` to depend on LiteRT-LM, replace imports + class references, get the existing 24+ JVM tests compiling and passing. No new features; same `MediaPipeBridge` interface; same handler behavior.

**Pass B: Cleanup + idiomatic adaptation.** After Pass A, audit the code for spots where the migration left awkward patterns (e.g. coroutine wrapping that's now redundant if LiteRT-LM is coroutine-native) and clean them up. Non-functional polish only.

### 4.5 Unchanged interfaces (parity contract)

```kotlin
interface MediaPipeBridgeApi {                    // STAYS THE SAME
    fun loadModel(modelPath: String, ...): Boolean
    fun unload()
    fun completePrompt(prompt: String, images: List<...>): String
    fun streamPrompt(prompt: String, images: List<...>, onToken: (String) -> Unit, onDone: (FinishReason) -> Unit)
    fun isVisionCapable(): Boolean
    // any additional methods inventoried during 3A
}

class MediaPipeHandlers(...) {                    // STAYS THE SAME
    // calls the bridge interface only; doesn't see MediaPipe / LiteRT-LM types directly
}
```

The `MPImage` type currently leaks through `MediaPipeBridge.completePrompt(prompt, images: List<MPImage>)`. **3B Task 1 includes interface neutralization:** replace the `List<MPImage>` parameter with `List<ByteArray>` (raw image bytes — same contract llama uses) so the bridge interface no longer references any MediaPipe-specific type. After that, the `*-core` package's bridge interface is portable across the two backend SDK options.

### 4.6 Test parity requirement

Every existing JVM test in `capacitor-mediapipe/android/src/test/` continues to pass after migration, with **at most surface-level changes** to test code:

- Mock bridges that happen to use `MPImage` in their test fixtures can change to `ByteArray` (the `MediaPipeBridge` interface change in §4.5).
- No existing test should fail; any new tests added for LiteRT-LM-specific edge cases are additive.

---

## 5. Cross-cutting — Android 16 KB page-size readiness

Google requires apps targeting API 35+ (Android 15+) to ship native libraries aligned to a 16 KB page size. Pixel devices already enforce in 2025; broad rollout in 2026. The current capacitor-mediapipe Android build doesn't compile any native code (MediaPipe ships its own .so), but capacitor-llama does — via its NDK CMake build of llama.cpp — and the upcoming `litert-lm` dependency in 3B may carry its own native libs.

### 5.1 Build flag

NDK r27+ aligns to 16 KB by default. Older NDK or older toolchains need explicit linker flags:

```cmake
target_link_options(jni-bridge PRIVATE
    -Wl,-z,max-page-size=16384
)
```

Or in `build.gradle`'s NDK block:

```gradle
externalNativeBuild {
    cmake {
        cppFlags "-Wl,-z,max-page-size=16384"
    }
}
```

The CMakeLists.txt that builds llama.cpp + the JNI shim picks up the flag and produces correctly aligned `.so` files.

### 5.2 Verification job

A new GitHub Actions step in the Android JVM CI workflow runs `objdump -p` on every produced `.so` and asserts page-alignment ≥ 16 KB. Fails the build if any binary is unaligned.

```bash
# Pseudo-script — actual implementation in 3A Task on CI workflow
for so in $(find android/build -name '*.so'); do
    size=$(objdump -p "$so" | awk '/LOAD/ && /align/ {print $NF; exit}')
    if [ "$size" -lt "16384" ]; then
        echo "::error::$so has page alignment $size, expected ≥ 16384"
        exit 1
    fi
done
```

### 5.3 16 KB emulator smoke test

Android Studio Hedgehog+ ships the 16 KB-page-size emulator system image. The smoke-real-models workflow's Android job switches to that image post-3A. The existing instrumented test passing on it = readiness verified.

---

## 6. Testing strategy

### 6.1 Test layers

| Layer | Where | Cadence |
|---|---|---|
| TS unit | `vitest` on ubuntu-latest | Every PR |
| iOS XCTest unit (per `*-core` package) | `xcodebuild test` on self-hosted Mac | Every PR |
| iOS XCTest integration (Capacitor wrapper) | `xcodebuild test` on self-hosted Mac | Every PR |
| Android JVM unit (per `*-core` package) | Gradle on ubuntu-latest | Every PR |
| Android JVM unit (Capacitor wrapper — minimal) | Gradle on ubuntu-latest | Every PR |
| Android instrumented (real-model smoke) | self-hosted runner with 16 KB sysimg | Nightly + pre-release |
| 16 KB alignment verification | objdump in Android workflow | Every PR |

### 6.2 Regression criterion

Phase 3A and 3B are landed only when:

- **Phase 3A:** every test that passes on `main` immediately before 3A starts also passes on `main` after 3A lands. Counts published in the Phase 3A milestone commit.
- **Phase 3B:** every test under `capacitor-mediapipe/android/src/test/` (24 today) passes against the LiteRT-LM-backed implementation. Plus any new LiteRT-LM-specific edge-case tests added during migration.

### 6.3 Continuous testing during refactor

Each Task in 3A's plan rebuilds + retests immediately on the affected package. We do not accumulate untested moves — the core extraction's risk is real (broken imports, missing files, lost test coverage), and cheap rebuild + retest is the mitigation.

---

## 7. Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Capacitor `cap sync` doesn't pick up project-relative Gradle modules in core packages | Med | High | Validate end-to-end in Phase 3A by syncing into a test Capacitor app and running the JS shim's `start()` |
| LiteRT-LM API substantially incompatible with the existing `MediaPipeBridge` interface | Med | Med | Bridge interface neutralization in 3B Task 1 (replace `MPImage` with `ByteArray`); revisit interface only if LiteRT-LM forces a deeper change |
| 16 KB-aligned `.so` is non-trivial on the older NDK we currently use | Low | Med | NDK r27+ aligns by default; bump if needed (small change, low blast radius) |
| iOS `Package.swift` version-conflict between core and capacitor packages | Low | Low | Use exact-version SPM dependency strings during dev; relax to caret-ranges before release |
| Test files moved across package boundaries lose CI coverage because of misconfigured workflows | Med | Med | Each test-relocation Task includes a CI-update sub-step; the milestone task verifies the workflow YAML actually picks up the new paths |
| LiteRT-LM artifact not yet published to Maven Central or named differently than expected | Low | Med | 3B Task 1 inventories exact artifact coordinates before changing build.gradle |
| LiteRT-LM has different memory profile and the Android smoke test OOMs differently | Low | Med | Per-method test invocation pattern carries forward (already proved out for iOS in Phase 2C) |

---

## 8. Open questions / deferred decisions

These are live questions that don't block 3A + 3B but should be resolved before downstream sub-phases:

1. **Native iOS SDK distribution:** Swift Package Index registration vs. CocoaPods first vs. both. Decided in 3C.
2. **Android Maven Central vs. JitPack:** Sonatype OSSRH onboarding lead time vs. JitPack's instant-publish but reduced trust. Decided in 3D.
3. **CoreML in 3C — model format support scope:** First version handles `.mlmodelc` text-generation only? Or aim for vision/audio at launch? Decided in 3C spec.
4. **LiteRT in 3D — TFLite vs. LiteRT-LM:** 3D introduces LiteRT as a third Android backend (in addition to llama.cpp via the core, and MediaPipe via mediapipe-core). LiteRT-LM (3B's target) handles LLM-specific cases; raw LiteRT/TFLite handles generic ONNX-like ML. Probably separate `android-litert-core` package — decided in 3D spec.
5. **.NET LLM IP (3G) — what specifically is "first-party":** Custom C# inference primitives layered on top of P/Invoke'd llama.cpp? Or a fully new C++ inference runtime? Decided in 3G spec.
6. **Multi-publish auth flow (3H):** GitHub OIDC for NuGet/Maven Central is increasingly common; will reduce stored secret count. Decided in 3H plan.

---

## 9. Definition of done (3A + 3B)

- [ ] 4 new `*-core` packages exist and build standalone.
- [ ] 3 capacitor-* packages refactored to depend on their cores; no native source code outside the core packages.
- [ ] All TS / iOS XCTest / Android JVM tests that pass on `main` pre-3A continue to pass post-3A.
- [ ] 16 KB-page-size CI verification job is green on every Android build.
- [ ] LiteRT-LM successfully replaces `tasks-genai` in `android-mediapipe-core`.
- [ ] All 24+ MediaPipe JVM tests pass against LiteRT-LM.
- [ ] `MediaPipeBridge` interface no longer leaks any MediaPipe / LiteRT-LM types (interface neutralization complete).
- [ ] `cap sync` end-to-end test passes against a freshly-set-up Capacitor host app for all three plugins.
- [ ] Branch merged to main with a clean rebase + fast-forward (per project conventions in CLAUDE.md).
