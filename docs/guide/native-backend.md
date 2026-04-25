# Native LLM (Capacitor)

DVAI-Bridge ships first-party Capacitor plugins that run a local
OpenAI-compatible HTTP server inside your iOS / Android app, fronted
by a native inference backend.

> [!NOTE]
> The previous `llama-cpp-capacitor` integration is **deprecated**.
> The replacement is the three-package family documented here. See
> [Migration notes](#migration-from-llama-cpp-capacitor) at the bottom
> of this page.

## Architecture

The Capacitor surface area is split across four packages:

```
@dvai-bridge/capacitor              ← JS routing shim (no native code)
  ├─ @dvai-bridge/capacitor-llama        ← native: llama.cpp
  ├─ @dvai-bridge/capacitor-foundation   ← native: Apple Foundation Models (iOS 26+)
  └─ @dvai-bridge/capacitor-mediapipe    ← native: MediaPipe LLM (Android)
```

You install the shim plus **one or more** backend plugins. The shim
chooses which backend's `start()` to call based on `StartOptions.backend`.

### How a backend plugin boots

1. JS calls `DVAIBridge.start({ backend, modelPath, ... })`.
2. The shim looks up the registered native plugin (`DVAIBridgeLlama`,
   `DVAIBridgeFoundation`, or `DVAIBridgeMediaPipe`) and dispatches.
3. The native side loads the model (mmap on iOS / Android), opens an
   HTTP server bound to `127.0.0.1:<port>`, and starts the `/v1/*`
   route handlers.
4. The promise resolves with `{ baseUrl, port, backend, modelId }`.
   `baseUrl` looks like `http://127.0.0.1:38883/v1`.

### What runs on which platform

| Plugin | iOS | Android |
|---|---|---|
| `capacitor-llama` | Swift + ObjC++ wrapping `llama.cpp` | Kotlin + JNI wrapping `libllama.so` |
| `capacitor-foundation` | Swift wrapping `LanguageModelSession` | Stub: returns `iOS-only` error |
| `capacitor-mediapipe` | Stub: returns `Android-only` error | Kotlin wrapping MediaPipe `LlmInference` |

The HTTP server library differs per OS:

- **iOS** — [Telegraph](https://github.com/Building42/Telegraph) (Swift NIO–based).
- **Android** — [NanoHTTPD](https://github.com/NanoHttpd/nanohttpd).

In both cases it serves the OpenAI-compatible surface (`/v1/chat/completions`,
`/v1/completions`, `/v1/models`, `/v1/embeddings` where applicable) plus
preflight CORS. The full route table lives in the Phase 1 design spec
in the source tree.

## Setup

See the [Capacitor quickstart](./quickstart-capacitor.md) for end-to-end
install + first-run code, including:

- Package install + `npx cap sync` flow.
- `DVAIBridge.start()` minimal example.
- Streaming SSE consumption.
- The `downloadModel()` helper for sha256-verified GGUF caching.
- Common errors and fixes.

## Choosing a backend

| Goal | Backend |
|---|---|
| Run any GGUF model, broadest selection | `llama` |
| Zero-download text on iOS 26+ | `foundation` |
| Vision-capable Gemma on Android | `mediapipe` |
| Embeddings | `llama` with `embeddingMode: true` |

See [Multimodal](./multimodal.md) for the per-backend image / audio
support matrix.

## Migration from `llama-cpp-capacitor`

Apps using the deprecated `llama-cpp-capacitor` plugin should migrate to
the new three-plugin family. The new API is OpenAI-compatible — you call
HTTP, not bridge methods, after `start()` returns.

### Before (deprecated)

```ts
import { LlamaCpp } from "llama-cpp-capacitor";

const ctx = await LlamaCpp.init({
  modelPath: "models/llama-2-7b.Q4_K_M.gguf",
  contextSize: 2048,
});

const reply = await LlamaCpp.completion(ctx.handle, {
  prompt: "Why is the sky blue?",
  maxTokens: 256,
});
```

### After (new)

```ts
import { DVAIBridge } from "@dvai-bridge/capacitor";

const { baseUrl, modelId } = await DVAIBridge.start({
  backend: "llama",
  modelPath: "/data/.../llama-3.2-1b.gguf",
  contextSize: 2048,
});

const res = await fetch(`${baseUrl}/chat/completions`, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    model: modelId,
    messages: [{ role: "user", content: "Why is the sky blue?" }],
    max_tokens: 256,
  }),
});
const data = await res.json();
const reply = data.choices[0].message.content;
```

### API mapping

| `llama-cpp-capacitor` | New equivalent |
|---|---|
| `LlamaCpp.init({ modelPath, contextSize, gpuLayers, threads })` | `DVAIBridge.start({ backend: "llama", modelPath, contextSize, gpuLayers, threads })` |
| `LlamaCpp.completion(handle, { prompt, maxTokens, … })` | `POST ${baseUrl}/chat/completions` (or `/completions`) |
| `LlamaCpp.tokenize(handle, text)` | Not yet exposed — file an issue if needed. |
| `LlamaCpp.embedding(handle, text)` | `POST ${baseUrl}/embeddings` after `start({ embeddingMode: true })`. |
| `LlamaCpp.release(handle)` | `DVAIBridge.stop()` (idempotent). |
| `nativeModelPath` core option | `modelPath` on `start()`. |

Differences to be aware of:

- The new API does **not** ship a default `nativeModelPath` resolver
  pointing at `public/models/`. You either pass an absolute path
  (typically from `downloadModel()`) or assemble one yourself from
  `Filesystem`.
- `llama.cpp` GPU-layers default is now `99` (request maximum offload);
  the runtime decides what's feasible.
- The HTTP boundary means you can swap in any OpenAI-compatible
  client (Vercel AI SDK, LangChain, the `openai` SDK with a
  `baseURL` override) without changing application code when you switch
  to a hosted endpoint later.

## See also

- [Capacitor quickstart](./quickstart-capacitor.md)
- [Model distribution](./model-distribution.md)
- [Multimodal](./multimodal.md)
- [Tested models](./tested-models.md)
