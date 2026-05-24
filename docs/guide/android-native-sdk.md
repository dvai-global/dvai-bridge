# Android Native SDK (`@dvai-bridge/android` / `co.deepvoiceai:dvai-bridge`)

`@dvai-bridge/android` is the standalone Android SDK that runs the
OpenAI-compatible local HTTP server *without* Capacitor. Drop it into a
Compose / Views / Kotlin Multiplatform app, call `start()`, point your
OpenAI client at the returned `baseUrl`.

If you're building a Capacitor app, you don't need this page — see
[Native LLM (Capacitor)](./native-backend.md) instead. This page is for
native Android apps.

## Install

The SDK is published to **Maven Central** under the group
`co.deepvoiceai`. No tokens, no auth — `mavenCentral()` is on the
default repo list for every Android project, so all you need is the
dependency line.

`app/build.gradle.kts`:

```kotlin
dependencies {
    implementation("co.deepvoiceai:dvai-bridge:4.0.0")
}
```

If your project explicitly manages repos in `settings.gradle.kts`, make
sure `mavenCentral()` is in the list (it is by default for new Android
Studio projects):

```kotlin
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}
```

The umbrella declares all four cores (`android-shared-core`,
`android-llama-core`, `android-mediapipe-core`, `android-litert-core`)
as `api` dependencies, so a single line gets every backend.

If you want a single backend without the others (e.g. you only use
LiteRT and want to avoid pulling llama.cpp's `~150 MB` of native libs),
declare just the relevant `*-core` artifact instead:

```kotlin
dependencies {
    implementation("co.deepvoiceai:android-litert-core:4.0.0")
    // No `dvai-bridge` umbrella, no llama-core, no mediapipe-core.
}
```

In that case you call `LiteRTPluginState` directly instead of
`DVAIBridge.start()`. The OpenAI HTTP surface is identical.

Platform floor: **`minSdk 24` (Android 7.0)**. AGP 9.2.0, Gradle 9.4.1+,
Kotlin 2.x, JVM target 17.

## Quickstart

```kotlin
import android.app.Application
import co.deepvoiceai.bridge.DVAIBridge
import co.deepvoiceai.bridge.StartOptions
import co.deepvoiceai.bridge.BackendKind

class MyApp : Application() {
    override fun onCreate() {
        super.onCreate()
        // One-time bootstrap — give the bridge an applicationContext.
        DVAIBridge.init(this)
    }
}

// Anywhere from a coroutine scope:
val server = DVAIBridge.start(StartOptions(
    backend = BackendKind.Auto,
    modelPath = "/sdcard/Download/Llama-3.2-1B-Instruct-Q4_K_M.gguf",
    contextSize = 2048,
    threads = 4,
))
println(server.baseUrl)  // http://127.0.0.1:38883/v1
println(server.port)     // 38883
println(server.backend)  // BackendKind.Llama (auto-resolved from .gguf)
```

Hit it with any OpenAI-compatible client:

```kotlin
val response = OkHttpClient().newCall(
    Request.Builder()
        .url("${server.baseUrl}/chat/completions")
        .post("""
            {"model": "${server.modelId}",
             "messages": [{"role": "user", "content": "Hello"}]}
        """.trimIndent().toRequestBody("application/json".toMediaType()))
        .build(),
).execute()
```

To stop:

```kotlin
DVAIBridge.stop()
```

## Backends

| `BackendKind` | Inference engine | Model format | minSdk | Notes |
|---|---|---|---|---|
| `Llama` | llama.cpp / Vulkan | GGUF | 24 | Broadest model coverage. CPU + Vulkan GPU offload. |
| `MediaPipe` | LiteRT-LM (post-Phase 3B) | `.task` / `.litertlm` | 24 | Google's bundled-task wrapper; vision support via EngineConfig. |
| `LiteRT` | Bare LiteRT (TFLite successor) | `.tflite` / `.litertlm` | 24 | New in Phase 3D. Llama-style stateful checkpoints; pure-Kotlin tokenizer.json BPE parsing. |
| `Auto` | Resolve at runtime | Inferred from `modelPath` | — | See [auto-resolution](#auto-resolution-rules) below. |

### Auto-resolution rules

Pass `BackendKind.Auto` and the SDK picks based on `modelPath`:

| `modelPath` | Resolves to |
|---|---|
| ends in `.task` and the file exists | `MediaPipe` |
| ends in `.tflite` or `.litertlm` | `LiteRT` |
| anything else (incl. `.gguf` and unknown extensions) | `Llama` |

`Llama` is the universal fallback because llama.cpp accepts the widest
range of GGUF quantizations.

## Compose integration: `DVAIBridge.reactive`

`DVAIBridge.reactive` returns a `DVAIBridgeReactiveState` whose
properties are `StateFlow`s ready to plug into Compose:

```kotlin
@Composable
fun BridgeStatus() {
    val isReady by DVAIBridge.reactive.isReady.collectAsState()
    val baseUrl by DVAIBridge.reactive.baseUrl.collectAsState()
    val backend by DVAIBridge.reactive.backend.collectAsState()

    if (isReady) {
        Text("Server: $baseUrl  ($backend)")
    } else {
        CircularProgressIndicator()
    }
}
```

Five `StateFlow` properties: `isReady`, `baseUrl`, `port`, `backend`,
`modelId`. They update synchronously on every `start()` / `stop()`.

## Progress events

Two equivalent surfaces, pick whichever fits your app:

```kotlin
// 1. SharedFlow — idiomatic Kotlin coroutines.
viewModelScope.launch {
    DVAIBridge.progressFlow.collect { event ->
        when (event) {
            is ProgressEvent.Started -> log("phase ${event.phase} started")
            is ProgressEvent.Progress -> updateUi(event.percent)
            is ProgressEvent.Completed -> log("done")
            is ProgressEvent.Failed -> showError(event.error)
        }
    }
}

// 2. Listener callback — Java-friendly + parity with iOS Combine.
val listener = ProgressListener { event ->
    Log.d("DVAI", "progress: $event")
}
DVAIBridge.addProgressListener(listener)
// ...
DVAIBridge.removeProgressListener(listener)
```

Both surfaces emit the same events in the same order. The
`SharedFlow` has a one-event replay buffer, so a late subscriber sees
the most-recent event.

## Errors

Every public method that can fail throws a [`DVAIBridgeError`](https://github.com/dvai-global/dvai-bridge/blob/main/packages/dvai-bridge-android/android/src/main/java/co/deepvoiceai/bridge/DVAIBridgeError.kt) (sealed Exception hierarchy):

| Error | When |
|---|---|
| `AlreadyStarted(currentBackend, baseUrl)` | `start()` called twice without `stop()`. |
| `ConfigurationInvalid(reason)` | Bad `StartOptions` (e.g. `Auto` resolution failed, missing context). |
| `ModelLoadFailed(reason)` | Backend rejected the model file or tokenizer. |
| `BackendUnavailable(backend, reason)` | Backend can't run in this build/env. |
| `BackendError(underlying)` | Generic backend failure (e.g. HTTP server bind, inference crash). |
| `ChecksumMismatch` | `downloadModel` sha256 didn't match. |
| `DownloadFailed(reason)` | `downloadModel` networking failure. |

Pattern-match in Kotlin:

```kotlin
try {
    DVAIBridge.start(opts)
} catch (e: DVAIBridgeError.AlreadyStarted) {
    // Roll over: stop, restart with new opts.
} catch (e: DVAIBridgeError.ModelLoadFailed) {
    // Tell the user the file's bad.
} catch (e: DVAIBridgeError.BackendUnavailable) {
    // Fall back to a different backend.
}
```

## Backend-specific notes

### LiteRT (`BackendKind.LiteRT`)

The LiteRT backend uses Google's newer TFLite-successor runtime
(`com.google.ai.edge.litert:litert:2.x`). It expects a
**Llama-style stateful** `.tflite` (or `.litertlm`) checkpoint with the
named tensors `input_ids`, `causal_mask` (optional), and `logits`.

**Tokenizer**: bring your own `tokenizer.json` (HuggingFace tokenizers
format). Path goes in `StartOptions.tokenizerPath`. The SDK ships a
pure-Kotlin BPE parser handling `model.type == "BPE"` with byte-level
pre-tokenization plus `added_tokens`. **SentencePiece / Unigram
tokenizers are not supported** — Gemma users should pick the MediaPipe
backend instead.

**Chat template**: only Llama-3-style and a plain concatenation
renderer are built-in. Pass `messages` as the standard OpenAI shape
(`[{role, content}, ...]`) and the LiteRT handler renders them via the
default `LLAMA3` template. Other model families need consumer
pre-rendering.

### MediaPipe (`BackendKind.MediaPipe`)

Uses Google's bundled-task LiteRT-LM artifact
(`com.google.ai.edge.litertlm:litertlm-android:0.10.x`) under the hood
since Phase 3B. Accepts `.task` checkpoints from
[MediaPipe LLM Inference task collection](https://ai.google.dev/edge/mediapipe/solutions/genai/llm_inference)
plus the newer `.litertlm` format.

Set `StartOptions.visionEnabled = true` to open the LiteRT-LM
`EngineConfig` with the vision backend enabled (Gemma 3n style
multimodal).

### Llama (`BackendKind.Llama`)

llama.cpp via JNI. Accepts any GGUF quantization. Supports vision/audio
encoders via `mmprojPath`. The Vulkan backend kicks in when
`gpuLayers > 0`; CPU-only mode uses NEON SIMD on ARM.

## Tests

The umbrella ships unit tests under
`packages/dvai-bridge-android/android/src/test/`:

- `DVAIBridgeAPIShapeTest` — reflection-based check on the public API surface.
- `BackendSelectorTest` — every dispatch branch.
- `ProgressBroadcasterTest` — Flow + listener parity.

Each `*-core` package ships its own backend-specific tests. Run them all
together via the in-repo helper after `bash scripts/android-publish-local.sh`:

```bash
cd packages/dvai-bridge-android-shared-core/android && ./gradlew test
cd packages/dvai-bridge-android-llama-core/android && ./gradlew test
# ...etc.
```

Real-model integration tests live under
`packages/dvai-bridge-android/android/src/androidTest/` (instrumented
tests on a connected device or emulator). Set
`SMOKE_MODEL_URL` / `SMOKE_MEDIAPIPE_MODEL_URL` /
`SMOKE_LITERT_MODEL_URL` env vars to enable them; they self-skip when
missing.

## Distributed inference (Phase 3)

`StartOptions` accepts an optional [`OffloadConfig`](https://bridge.deepvoiceai.co/docs/guide/distributed-inference)
that turns on LAN peer discovery + capability-aware request offload.

```kotlin
import co.deepvoiceai.bridge.shared.core.offload.OffloadConfig

DVAIBridge.init(applicationContext)

val server = DVAIBridge.start(
    StartOptions(
        backend = BackendKind.Auto,
        modelPath = "/path/to/model.gguf",
        offload = OffloadConfig(
            enabled = true,           // master switch — default false (v2.x parity)
            discoverLAN = true,       // NsdManager (mDNS) discovery for `_dvai-bridge._tcp`
            minLocalCapability = 10.0,// below this tok/s, look for a peer
            rendezvousUrl = null,     // optional WSS rendezvous URL for internet pairings
        ),
    ),
)

// Pairing requests from peers — surface to the user via Compose / Material 3:
lifecycleScope.launch {
    DVAIBridge.pairingRequests.collect { req ->
        val approved = showPairingDialog(req.peerDeviceName)
        req.respond(approved)
    }
}
```

When `offload.enabled = true`, the SDK also:

- Persists a stable per-install device id under
  `applicationContext.cacheDir/dvai-bridge/device.json`.
- Caches per-(model, library version) capability scores under
  `applicationContext.cacheDir/dvai-bridge/capability.json`.
- Persists approved pairings under
  `applicationContext.cacheDir/dvai-bridge/pairings.json` (HMAC-SHA256
  shared key, base64-url, 30-day inactivity TTL).
- Advertises this device via `NsdManager.registerService` as a
  `_dvai-bridge._tcp` service so peers on the same Wi-Fi can find it.

`stop()` tears all of this back down before releasing the HTTP port.

The `kotlinx.coroutines.flow.SharedFlow` returned by
`DVAIBridge.pairingRequests` is hot — collect it from a
`LifecycleOwner.lifecycleScope` and the requests are dropped (default-deny)
when no UI is bound.

## Outgoing offload (v3.2)

In v3.0/v3.1, only the *strong-peer side* (the device serving
inference) was wired up natively. Consumer apps still had to talk
to the peer via raw OkHttp + manual HMAC signing. v3.2 closes that
loop: when `OffloadConfig.enabled = true`, the SDK runs a Ktor
pre-routing proxy in front of the native backend. Every
chat-completion request through the SDK's public `baseUrl` is
inspected and either served locally or forwarded to a paired peer
— transparently, with no consumer code change.

```kotlin
val server = DVAIBridge.start(
    StartOptions(
        backend = BackendKind.Auto,
        modelPath = "/path/to/model.gguf",
        offload = OffloadConfig(enabled = true),
    ),
)

// `server.baseUrl` is the proxy port. Use any OkHttp / OpenAI client.
val client = OkHttpClient()
val response = client.newCall(
    Request.Builder()
        .url("${server.baseUrl}/v1/chat/completions")
        .post(jsonBody)
        .build()
).execute()
```

### Pre-init hardware assessment

Before any model download or backend init, ask the SDK how this
device will behave:

```kotlin
val a = DVAIBridge.assessHardware(
    hardwareMinimum = 3.0,
    minLocalCapability = 10.0,
)
when (a.mode) {
    PrecheckMode.OK -> DVAIBridge.start(opts)
    PrecheckMode.OFFLOAD_ONLY -> DVAIBridge.start(opts)  // SDK skips backend
    PrecheckMode.TOO_WEAK -> showCustomNotSupportedDialog(a.reason)
}
```

The SDK never shows UI for hardware decisions — your app does.
See the [distributed-inference guide](./distributed-inference.md#v32--per-sdk-outgoing-offload-routing)
for the full `assessHardware()` contract.

## Reference

- [Public Kotlin API](../reference/api.md)
- [Backends comparison](./backends.md)
- [Distributed inference guide](./distributed-inference.md)
- iOS counterpart: [iOS Native SDK](./ios-native-sdk.md)
