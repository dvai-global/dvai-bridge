# `examples/android-litert`

Minimal Compose app exercising the DVAIBridge Android Native SDK with
the **LiteRT** backend (Google's TFLite-successor runtime, used here
for Llama-style stateful `.tflite` checkpoints driven through bare
`CompiledModel` calls).

The app shows a single button — tap it, and the app:

1. Calls `DVAIBridge.start(StartOptions(backend = BackendKind.LiteRT, ...))`
   pointing at a `.tflite` checkpoint and a `tokenizer.json` directory
   on the device's external storage.
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
2. **File → Open** → select `examples/android-litert/`.
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
cd examples/android-litert
./gradlew assembleDebug test

# 3. (optional) End-to-end on a connected device:
./gradlew connectedAndroidTest
```

The full smoke entry point is `bash examples/android-litert/smoke.sh`.

## Model

| Field | Value |
| ----- | ----- |
| Model | `litert-community/Llama-3.2-1B-Instruct` (Q4 .tflite) |
| Format | LiteRT `.tflite` (Llama-style stateful checkpoint) |
| Size | ~1.0 GB (model) + ~5 MB (tokenizer.json) |
| Model cache | `/sdcard/Download/Llama-3.2-1B-Instruct.tflite` |
| Tokenizer cache | `/sdcard/Download/litert-tokenizer/tokenizer.json` |

The example does **not** download anything. Push the model + tokenizer
once:

```bash
# Pull the .tflite + tokenizer.json from
#   https://huggingface.co/litert-community/Llama-3.2-1B-Instruct
# (or any other Llama-style stateful .tflite under that org's repos)

adb push Llama-3.2-1B-Instruct.tflite /sdcard/Download/
adb shell mkdir -p /sdcard/Download/litert-tokenizer
adb push tokenizer.json /sdcard/Download/litert-tokenizer/
```

> **Tokenizer caveat:** the LiteRT backend ships a pure-Kotlin
> HuggingFace BPE parser. SentencePiece / Unigram tokenizers (Gemma)
> are **not supported** — Gemma users should pick `android-mediapipe`
> instead.

## Runtime requirements

- `minSdk 24` (Android 7.0+).
- `arm64-v8a` or `x86_64` ABI (LiteRT 2.x bundles native libs for both).
- The LiteRT runtime auto-selects the best delegate at start time; on
  Android 12+ devices with a hardware GPU/NPU it transparently falls
  back to the GPU delegate. CPU-only is the universal fallback (XNNPACK
  via the bundled JNI).

## Where the OpenAI client points at the local endpoint

[`MainActivity.kt`](app/src/main/java/co/deepvoiceai/example/litert/MainActivity.kt)
constructs the OpenAI client like:

```kotlin
val state = DVAIBridge.start(StartOptions(
    backend = BackendKind.LiteRT,
    modelPath = "...tflite",
    tokenizerPath = "...litert-tokenizer/",
))
val openai = OpenAI(host = OpenAIHost(baseUrl = state.baseUrl + "/"), token = "ignored")
openai.chatCompletions(...)
```

## Troubleshooting

- **"Model file missing"** / **"tokenizer.json missing"** — the
  first-run hints. Run the two `adb push` commands above.
- **`ModelLoadFailed` thrown from `start()`** — the `.tflite` is not a
  Llama-style stateful checkpoint (missing the `input_ids`,
  `causal_mask`, `logits` named tensors). LiteRT-with-DVAI accepts
  only that shape; classifier `.tflite`s won't work.
- **Garbled output** — usually a tokenizer mismatch. The model and
  `tokenizer.json` must come from the same HF repo.
- **Gradle sync fails resolving `co.deepvoiceai:dvai-bridge:2.4.1`** —
  re-run the `android-publish-local` script. `mavenLocal()` goes stale
  whenever the SDK source changes.
