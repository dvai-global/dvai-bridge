# `examples/android-mediapipe`

Minimal Compose app exercising the DVAIBridge Android Native SDK with
the **MediaPipe (LiteRT-LM)** backend.

The app shows a single button — tap it, and the app:

1. Calls `DVAIBridge.start(StartOptions(backend = BackendKind.MediaPipe, ...))`
   pointing at a `.task` checkpoint on the device's external storage.
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
2. **File → Open** → select `examples/android-mediapipe/`.
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
cd examples/android-mediapipe
./gradlew assembleDebug test

# 3. (optional) End-to-end on a connected device:
./gradlew connectedAndroidTest
```

The full smoke entry point is `bash examples/android-mediapipe/smoke.sh`.

## Model

| Field | Value |
| ----- | ----- |
| Model | Gemma-2-2B-IT (`gemma2-2b-it-cpu-int8.task`) |
| Format | MediaPipe LLM `.task` bundle |
| Size | ~1.3 GB |
| Cache | `/sdcard/Download/gemma2-2b-it-cpu-int8.task` |

The example does **not** download the model. Pull the canonical bundle
from Google's MediaPipe LLM Inference task collection and push it once:

```bash
# MediaPipe LLM tasks live at
#   https://ai.google.dev/edge/mediapipe/solutions/genai/llm_inference
# Pick the Gemma-2-2B variant (Kaggle-hosted; the URL changes on each
# Kaggle release rotation, so resolve it from the docs page).

adb push gemma2-2b-it-cpu-int8.task \
    /sdcard/Download/gemma2-2b-it-cpu-int8.task
```

You can also use any other `.task` artifact in the collection (e.g.
`gemma-3n-E2B-it` for vision-capable inputs). Update `MODEL_FILENAME` in
[`MainActivity.kt`](app/src/main/java/co/deepvoiceai/example/mediapipe/MainActivity.kt)
to match. Memory footprint at runtime is ~1.1–1.3× on-disk.

## Runtime requirements

- `minSdk 24` (Android 7.0+).
- `arm64-v8a` (the LiteRT-LM AAR ships native libs for ARM only;
  `x86_64` works for the JVM portion but inference falls back to the
  CPU path on emulators).
- For the **QNN delegate** (Hexagon NPU offload on Snapdragon parts),
  the LiteRT-LM SDK requires Snapdragon 8 Gen 2 or newer; older parts
  silently fall back to the CPU path.
- For **vision** (`StartOptions.visionEnabled = true`), the chosen
  `.task` must be a vision-enabled Gemma variant. The example does
  not enable vision by default — flip the flag and pass image content
  parts in the chat request to exercise it.

## Where the OpenAI client points at the local endpoint

[`MainActivity.kt`](app/src/main/java/co/deepvoiceai/example/mediapipe/MainActivity.kt)
constructs the OpenAI client like:

```kotlin
val state = DVAIBridge.start(StartOptions(backend = BackendKind.MediaPipe, modelPath = ...))
val openai = OpenAI(host = OpenAIHost(baseUrl = state.baseUrl + "/"), token = "ignored")
openai.chatCompletions(...)
```

The `baseUrl` is `http://127.0.0.1:<port>/v1` — `aallam/openai-kotlin`
treats `host.baseUrl` as the prefix it concatenates onto OpenAI route
paths, so the trailing `/` matters.

## Troubleshooting

- **"Model file missing at /sdcard/Download/…"** — the first-run hint.
  Run the `adb push` command above and retry.
- **`BackendUnavailable` thrown from `start()`** — the LiteRT-LM AAR
  failed to load its native libs. Common causes: running on an
  `armeabi-v7a` device (only `arm64-v8a` is supported) or a stripped
  emulator image. Switch to a 64-bit device/emulator.
- **Gradle sync fails resolving `co.deepvoiceai:dvai-bridge:2.4.1`** —
  re-run the `android-publish-local` script. `mavenLocal()` goes stale
  whenever the SDK source changes.
