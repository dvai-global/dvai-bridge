# `examples/android-llama`

Minimal Compose app exercising the DVAIBridge Android Native SDK with
the **Llama (llama.cpp)** backend.

The app shows a single button — tap it, and the app:

1. Calls `DVAIBridge.start(StartOptions(backend = BackendKind.Llama, ...))`
   pointing at a GGUF model on the device's external storage.
2. Hands the returned `state.baseUrl` to `aallam/openai-kotlin`.
3. Streams a chat completion for the prompt *"Tell me a joke."* into
   the UI.

## Prereqs

- **Android Studio** (Ladybug 2024.x or newer; ships JDK 21+ via JBR).
- **Android SDK 36** (or 35 — the Gradle `compileSdkOverride` defaults
  to 35 on Windows to sidestep an AGP 9.2.0 / android-36 parser bug).
- **AGP 9.x / Gradle 9.4.1+** (managed by the wrapper in this dir).
- **Kotlin 2.3.x** (matches the SDK cores' pin).
- A **physical Android device or emulator** if you want to run
  `connectedAndroidTest` end-to-end. JVM unit tests run on any host.

## How to open in Android Studio

1. Open Android Studio.
2. **File → Open** → select `examples/android-llama/`.
3. When prompted, accept the Gradle sync.
4. Run the `app` configuration on a device or emulator.

## How to run from the CLI

```bash
# 1. Publish the SDK to mavenLocal (one-time per SDK source change).
#    Windows:
pwsh scripts/android-publish-local.ps1
#    Mac/Linux:
bash scripts/android-publish-local.sh

# 2. Build + run the unit smoke tests.
cd examples/android-llama
./gradlew assembleDebug test

# 3. (optional) End-to-end on a connected device:
./gradlew connectedAndroidTest
```

The full smoke entry point is `bash examples/android-llama/smoke.sh`.

## What to expect on first run

- Cold Gradle sync downloads the AGP / Compose toolchain (~150 MB).
- App APK is ~30 MB plus the umbrella's native libs (~150 MB combined
  across the four cores; the example only links the umbrella, so all
  four ship even though only `Llama` is exercised. Consumers who want a
  Llama-only shell can swap the umbrella dep for
  `co.deepvoiceai:android-llama-core:2.4.1` instead — see the SDK
  README's "single-backend" snippet).

## Model

| Field | Value |
| ----- | ----- |
| Model | `bartowski/Llama-3.2-1B-Instruct-GGUF` (Q4_K_M variant) |
| Format | GGUF |
| Size | ~770 MB |
| Cache | `/sdcard/Download/Llama-3.2-1B-Instruct-Q4_K_M.gguf` |

The example does **not** download the model on app launch. Push it once:

```bash
# Grab the GGUF (~770 MB) from Hugging Face:
#   https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF
# File: Llama-3.2-1B-Instruct-Q4_K_M.gguf

adb push Llama-3.2-1B-Instruct-Q4_K_M.gguf \
    /sdcard/Download/Llama-3.2-1B-Instruct-Q4_K_M.gguf
```

Memory footprint at runtime is ~1.5× on-disk (~1.2 GB peak). Anything
mid-range and newer (Snapdragon 7-series, Tensor G2+, A55+) handles it
comfortably; older mid-range may thermal-throttle on long generations.

## Runtime requirements

- `minSdk 24` (Android 7.0+).
- `arm64-v8a` or `x86_64` ABI (the umbrella's native libs are pinned to
  these — no 32-bit support).
- Vulkan-capable GPU is **not** required (the Llama backend defaults to
  CPU + NEON SIMD on ARM); pass `gpuLayers = 0` in `StartOptions` to
  force CPU-only if you see Vulkan-related crashes on your device.

## Where the OpenAI client points at the local endpoint

[`MainActivity.kt`](app/src/main/java/co/deepvoiceai/example/llama/MainActivity.kt)
constructs the OpenAI client like:

```kotlin
val state = DVAIBridge.start(StartOptions(backend = BackendKind.Llama, modelPath = ...))
val openai = OpenAI(host = OpenAIHost(baseUrl = state.baseUrl + "/"), token = "ignored")
openai.chatCompletions(...)
```

The `baseUrl` is `http://127.0.0.1:<port>/v1` — `aallam/openai-kotlin`
treats `host.baseUrl` as the prefix it concatenates onto OpenAI route
paths, so the trailing `/` matters.

## Troubleshooting

- **"Model file missing at /sdcard/Download/…"** — the first-run hint.
  Run the `adb push` command above and retry.
- **Gradle sync fails resolving `co.deepvoiceai:dvai-bridge:2.4.1`** —
  re-run `pwsh scripts/android-publish-local.ps1` (Windows) or
  `bash scripts/android-publish-local.sh` (Mac/Linux). `mavenLocal()`
  goes stale whenever the SDK source changes.
- **`parseLocalResources` build failure on Windows** — covered by the
  `compileSdkOverride=35` default in `gradle.properties`. Pass
  `-PcompileSdkOverride=36` to opt back in once your AGP/Windows pair
  ships the upstream fix.
