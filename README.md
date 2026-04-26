![DVAI-Bridge](/assets/banner.png)

# DVAI-Bridge

<!-- Smoke badge stays here; goes live after the first scheduled run posts a
     status to the default branch. The repo is private pre-launch, so the
     badge will 404 / display "no status" until then — keep the line in
     place so a post-launch flip is a single-line edit, not a layout pass. -->
[![Smoke — real models](https://github.com/Westenets/dvai-bridge/actions/workflows/smoke-real-models.yml/badge.svg?branch=main)](https://github.com/Westenets/dvai-bridge/actions/workflows/smoke-real-models.yml)

**The local OpenAI server you embed inside your app.**

DVAI-Bridge starts a real OpenAI-compatible HTTP server on `127.0.0.1`,
inside your application's own process, on every major client platform. Point
LangChain, the OpenAI SDK, the Vercel AI SDK, or any OpenAI-compatible
client at it. No Ollama install. No backend. No API keys. No cloud. Zero
cost per token.

```ts
import { DVAI } from "@dvai-bridge/core";
import OpenAI from "openai";

const dvai = new DVAI({ backend: "transformers" });
await dvai.initialize();
// Local OpenAI-compatible server is live.

const openai = new OpenAI({ baseURL: dvai.baseUrl, apiKey: "ignored" });
const r = await openai.chat.completions.create({
  model: dvai.transformersModelId,
  messages: [{ role: "user", content: "Hello!" }],
});
```

Same library, same OpenAI surface — JavaScript, Swift, Kotlin, and C#
apps across web, mobile, Electron, and native desktop. Your agent code
never changes.

Built by **[Deep Voice AI](https://deepvoiceai.co)**.

---

## Why this exists

Developers prototype local AI agents against **Ollama + LangChain** on
their laptop and it works beautifully. Then they try to ship the app and
hit a wall: **Ollama is a separate install.** Their users don't have it.
Their mobile app can't run it. Their corporate IT forbids adding another
daemon.

Every other approach requires reinventing the same plumbing: spawn an
inference engine, bind to a port, translate to the OpenAI HTTP shape,
handle CORS for webviews, manage lifecycle on unload, wrap the accelerator
of the day per platform — then do it again for every target OS.

DVAI-Bridge is that plumbing, packaged as a library, for every client
platform. One `initialize()` call gives you a live local OpenAI endpoint.
Every major stack. Any language that speaks HTTP.

---

## Key properties

- **Embedded, not installed.** A library — `import`, `initialize`, done.
  Your end users install nothing extra.
- **OpenAI HTTP is the universal contract.** Your agent code keeps using
  whatever OpenAI SDK it already uses. No DVAI-Bridge-specific API to learn.
- **Runs anywhere your app does.** Browser, Node, Electron, Capacitor
  mobile, native Android, native iOS, and .NET desktop — one library per
  runtime, identical HTTP endpoint across all of them.
- **Transport auto-detection.** Browser → MSW intercept. Node / native
  runtimes → real `http.createServer` (or platform equivalent) on loopback.
  Host apps read `dvai.baseUrl` (or the platform-equivalent return from
  `start()`) and pass it to any OpenAI SDK.
- **Port fallback built in.** Starts at reserved port `38883` and falls
  forward on `EADDRINUSE`. Multi-instance-safe on every platform.
- **Private Network Access ready.** HTTPS pages and webviews can call the
  loopback server — CORS + PNA headers on every response, out of the box.
- **Native acceleration per platform.** CUDA / Metal / Vulkan / DirectML
  on desktop; CoreML / Apple Foundation Models / MLX on iOS; NNAPI / QNN
  / MediaPipe LLM on Android; WebGPU in the browser.
- **Backend-pluggable.** WebLLM, Transformers.js, llama.cpp, CoreML, ONNX
  Runtime GenAI, LiteRT, Apple Foundation Models, MediaPipe LLM — all
  selectable; all invisible to the agent code that consumes the endpoint.
- **Multi-modal.** Text, image, audio, video via pipeline backends.
  Declarative loader for cutting-edge models (Gemma 4, LLaVA, Idefics, etc.)
  without waiting for library updates.
- **Streaming-correct.** SSE passthrough, blank-chunk detection,
  generation timeout, automatic engine-state recovery on fatal errors.
- **First-party native code.** Every binding — NAPI, JNI, Swift/ObjC++,
  P/Invoke — is ours. llama.cpp is consumed as pinned upstream source
  and built into our binaries. No transitive third-party wrappers.

---

## Supported platforms

| Stack | Package | Transport | Inference backends |
|---|---|---|---|
| Browser (React, Vue, Svelte, vanilla JS) | `@dvai-bridge/core` + `@dvai-bridge/react` or `@dvai-bridge/vanilla` | MSW intercept | WebLLM (WebGPU), Transformers.js (WebGPU / WASM SIMD) |
| Node / Bun | `@dvai-bridge/core` | HTTP 127.0.0.1 | Transformers.js, native llama.cpp |
| Electron | `@dvai-bridge/core` | HTTP (main) / MSW (renderer) | Native llama.cpp (CUDA / Metal / Vulkan / DirectML), Transformers.js |
| Capacitor hybrid mobile (iOS + Android) | `@dvai-bridge/capacitor` | HTTP 127.0.0.1 | Native llama.cpp (Metal on iOS, Vulkan / CPU on Android) |
| Android native (Kotlin / Java) | `co.deepvoiceai:dvai-bridge` AAR | HTTP 127.0.0.1 | llama.cpp, LiteRT, MediaPipe LLM, NNAPI / QNN Hexagon |
| iOS native (Swift) | `DVAIBridge` Swift Package | HTTP 127.0.0.1 | llama.cpp (Metal), CoreML / ANE, Apple Foundation Models |
| Windows / Mac / Linux desktop (.NET) | `DeepVoiceAI.DVAIBridge` NuGet | HTTP 127.0.0.1 | llama.cpp, ONNX Runtime GenAI, DirectML |

**React Native / Flutter / Tauri:** use the iOS Swift Package or Android
AAR directly via standard native-bridge patterns. Dedicated React Native
and Flutter wrappers are on the near-term roadmap.

See [`POSITIONING.md`](./POSITIONING.md) and [`docs/guide/comparison.md`](./docs/guide/comparison.md)
for how DVAI-Bridge compares to Ollama, `llama-server`, LM Studio, and
other local-AI tools.

---

## Packages

### JavaScript / TypeScript

| Package | Use it for |
|---|---|
| `@dvai-bridge/core` | Core library: backend engines, transport abstraction, handler module, OpenAI surface. Works in browser, Node, and Electron. |
| `@dvai-bridge/react` | React Context Provider + `useDVAI` hook. |
| `@dvai-bridge/vanilla` | Wrapper for non-framework environments (vanilla JS / CDN). |
| `@dvai-bridge/capacitor` | Capacitor plugin that boots the HTTP server natively on iOS + Android. |

### Native platforms

| Platform | Package / identifier | Package manager |
|---|---|---|
| iOS (Swift) | `DVAIBridge` | Swift Package Manager |
| Android (Kotlin / Java) | `co.deepvoiceai:dvai-bridge` | Maven Central |
| Windows / Mac / Linux (.NET) | `DeepVoiceAI.DVAIBridge` | NuGet |

---

## Installation

### JavaScript / TypeScript

Install the core and the backend you need. Peer dependencies — install only
what your app uses.

```bash
# Transformers.js (recommended — works on web and Node, widest model variety)
npm install @dvai-bridge/core @huggingface/transformers

# WebLLM (browser only, MLC-compiled models, fastest for supported models)
npm install @dvai-bridge/core @mlc-ai/web-llm

# With React helpers
npm install @dvai-bridge/react

# Vanilla JS / CDN
npm install @dvai-bridge/vanilla

# Capacitor hybrid mobile
npm install @dvai-bridge/capacitor
npx cap sync
```

For browser apps, copy the MSW service worker and inference workers into
your `public/` directory once:

```bash
npx dvai-bridge init [public-dir]
```

### iOS (Swift)

Add to your `Package.swift`:

```swift
dependencies: [
  .package(url: "https://github.com/Westenets/dvai-bridge-swift", from: "1.0.0"),
]
```

Or via Xcode: File → Add Packages → paste the repo URL.

### Android (Kotlin / Java)

Add to `build.gradle.kts`:

```gradle
dependencies {
    implementation("co.deepvoiceai:dvai-bridge:1.0.0")
}
```

Then add cleartext-to-loopback permission to your
`network_security_config.xml`. The library ships a recommended snippet —
most Gradle configs can include it via a manifest merge one-liner.

### .NET desktop (C#)

```bash
dotnet add package DeepVoiceAI.DVAIBridge
```

---

## Usage

### Node / Electron main

```js
import { DVAI } from "@dvai-bridge/core";
import OpenAI from "openai";

const dvai = new DVAI({ backend: "transformers" });
await dvai.initialize();
console.log(`DVAI live at ${dvai.baseUrl}`); // http://127.0.0.1:38883/v1

const openai = new OpenAI({ baseURL: dvai.baseUrl, apiKey: "ignored" });
const r = await openai.chat.completions.create({
  model: dvai.transformersModelId,
  messages: [{ role: "user", content: "Hello!" }],
});
console.log(r.choices[0].message.content);
```

### React

```tsx
import { DVAIProvider, useDVAI } from "@dvai-bridge/react";

function App() {
  return (
    <DVAIProvider
      config={{
        backend: "transformers",
        transformersModelId: "onnx-community/gemma-3n-E2B-it-ONNX",
      }}
    >
      <Chat />
    </DVAIProvider>
  );
}

function Chat() {
  const { isReady, progress, baseUrl, backend } = useDVAI();
  if (!isReady) return <div>Loading ({backend}): {progress.text}</div>;
  return <div>Local AI live at {baseUrl}</div>;
}
```

### Vanilla JS / CDN

```html
<script src="https://cdn.jsdelivr.net/npm/@dvai-bridge/vanilla/dist/index.global.js"></script>
<script>
  const ai = new VanillaDVAI({ backend: "transformers" });
  await ai.initialize();
  console.log("Local AI live at", ai.getBaseUrl());
</script>
```

### iOS (Swift)

```swift
import DVAIBridge
import OpenAI

let dvai = try await DVAIBridge.shared.start()
// dvai.baseUrl: "http://127.0.0.1:38883/v1"

let openai = OpenAI(apiToken: "ignored", baseURL: dvai.baseUrl)
let response = try await openai.chats(
  query: ChatQuery(
    messages: [.init(role: .user, content: "Hello!")],
    model: dvai.modelId
  )
)
print(response.choices.first?.message.content ?? "")
```

### Android (Kotlin)

```kotlin
import co.deepvoiceai.dvaibridge.DvaiBridge
import com.aallam.openai.client.OpenAI

val dvai = DvaiBridge.start(context)
// dvai.baseUrl: "http://127.0.0.1:38883/v1"

val openai = OpenAI(
  host = OpenAIHost(baseUrl = dvai.baseUrl),
  token = "ignored"
)
val response = openai.chatCompletion(
  ChatCompletionRequest(
    model = ModelId(dvai.modelId),
    messages = listOf(ChatMessage(role = ChatRole.User, content = "Hello!"))
  )
)
println(response.choices.first().message.content)
```

### .NET desktop (C#)

```csharp
using DeepVoiceAI.DVAIBridge;
using OpenAI;

var dvai = await DVAIBridge.StartAsync();
// dvai.BaseUrl: "http://127.0.0.1:38883/v1"

var openai = new OpenAIClient(new ApiKeyCredential("ignored"),
  new OpenAIClientOptions { Endpoint = new Uri(dvai.BaseUrl) });

var chat = openai.GetChatClient(dvai.ModelId);
var response = await chat.CompleteChatAsync("Hello!");
Console.WriteLine(response.Value.Content[0].Text);
```

### Capacitor mobile

```ts
import { DVAIBridge } from "@dvai-bridge/capacitor";
import OpenAI from "openai";

const { baseUrl } = await DVAIBridge.start({
  modelPath: "ggml-gemma-2b-q4.gguf",  // bundled with the app
});
// baseUrl: "http://127.0.0.1:38883/v1"

const openai = new OpenAI({ baseURL: baseUrl, apiKey: "ignored" });
const r = await openai.chat.completions.create({
  model: "gemma-2b",
  messages: [{ role: "user", content: "Hello!" }],
});
```

### Direct inference (no HTTP surface)

Useful inside a Web Worker or when you explicitly want to skip the server:

```ts
const ai = new DVAI({
  backend: "transformers",
  transport: "none",
});
await ai.initialize();

const r = await ai.chatCompletion({
  messages: [{ role: "user", content: "Hello!" }],
  max_tokens: 100,
});
```

### Multi-modal (Transformers.js / native llama.cpp)

```ts
// Text-to-image
const imageAI = new DVAI({
  backend: "transformers",
  transformersModelId: "Xenova/stable-diffusion-v1-4",
  pipelineTask: "text-to-image",
});
await imageAI.initialize();
const img = await imageAI.runPipeline("A cute cat in space");

// Speech recognition
const asrAI = new DVAI({
  backend: "transformers",
  transformersModelId: "Xenova/whisper-tiny.en",
  pipelineTask: "automatic-speech-recognition",
});
await asrAI.initialize();
const transcript = await asrAI.runPipeline(audioBuffer);
```

---

## Resource management (mobile & laptop)

AI models eat RAM and battery. Unload when you're done:

```ts
// React
const { unload, init } = useDVAI();
await unload();            // free model + stop transport
await init();              // reload when needed

// Vanilla / Node
await dvai.unload();
await dvai.initialize();
```

Native platforms expose the same pattern — `stop()` to release resources,
`start()` to reload.

---

## Robustness

- **Blank chunk detection** — aborts streaming after too many blanks
  (`maxBlankChunks`, default 20).
- **Generation timeout** — prevents infinite loops (`generationTimeout`,
  default 60 s).
- **Engine state recovery** — resets the backend on fatal errors and
  retries up to `maxRetries` (default 2) times.
- **Stream finish-reason checks** — terminates cleanly on `stop` or `length`.
- **Worker / thread offloading** — inference runs off the UI thread on
  every platform; graceful fallback if workers are unavailable.

---

## Hardware acceleration

Acceleration is handled per platform; the developer never writes
accelerator-specific code. Selection happens at runtime based on
availability.

| Platform | Primary | Secondary | CPU fallback |
|---|---|---|---|
| Web | WebGPU | WebNN | WASM SIMD |
| Desktop (Electron, .NET) | CUDA / Metal / Vulkan | DirectML (Windows) | AVX2 / AVX-512 |
| Android | MediaPipe LLM + QNN (Hexagon) | NNAPI, GPU delegate | XNNPACK |
| iOS | Apple Foundation Models / CoreML / ANE | Metal | XNNPACK |

---

## Configuration reference

Core options (JS / TS — other platforms expose equivalent config on their
start-options type):

| Option | Type | Default | Description |
|---|---|---|---|
| `backend` | `"webllm" \| "transformers" \| "native" \| "auto"` | `"auto"` | Inference backend. `"auto"` picks the best for the runtime. |
| `modelId` | `string` | `"gemma-2-2b-it-q4f16_1-MLC"` | WebLLM model ID |
| `transformersModelId` | `string` | `"onnx-community/gemma-3n-E2B-it-ONNX"` | HuggingFace model ID |
| `pipelineTask` | `string` | `"text-generation"` | Transformers.js pipeline task |
| `device` | `"webgpu" \| "cpu" \| "auto"` | `"auto"` | Transformers.js device |
| `dtype` | `string` | — | Quantization (e.g. `"q4"`, `"q8"`, `"f16"`) |
| `generationTimeout` | `number` | `60000` | Max generation time (ms) |
| `maxBlankChunks` | `number` | `20` | Blank chunks before stream abort (WebLLM) |
| `maxRetries` | `number` | `2` | Max auto-recovery retries |
| `transport` | `"auto" \| "msw" \| "http" \| "none"` | `"auto"` | Transport selection. `"auto"` picks MSW in browser, HTTP in Node. |
| `httpBasePort` | `number` | `38883` | HTTP transport base port (retries +1 up to 16 times) |
| `httpMaxPortAttempts` | `number` | `16` | Max HTTP port fallback attempts |
| `corsOrigin` | `string \| string[]` | `"*"` | HTTP `Access-Control-Allow-Origin` value or allowlist |
| `mockUrl` | `string` | `"https://api.openai.local/v1/chat/completions"` | MSW intercept URL (ignored under HTTP) |
| `serviceWorkerUrl` | `string` | `"/mockServiceWorker.js"` | Path to MSW service worker |
| `webllmWorkerUrl` | `string` | `"/dvai-webllm.worker.js"` | Path to WebLLM inference worker |
| `transformersWorkerUrl` | `string` | `"/dvai-transformers.worker.js"` | Path to Transformers.js inference worker |
| `transformersModelClass` | `string` | — | Declarative multimodal loader class (e.g. `"Gemma4ForConditionalGeneration"`) |
| `transformersProcessorClass` | `string` | `"AutoProcessor"` | Processor class for the declarative loader |
| `transformersDisableEncoders` | `string[]` | `[]` | Null out model submodule fields post-load (e.g. `["vision_encoder"]`) |
| `createPipeline` | `CreatePipelineFn` | — | Custom main-thread pipeline factory |
| `nativeModelPath` | `string` | — | GGUF model path (native backend) |
| `nativeGpuLayers` | `number` | `99` | GPU layers (iOS Metal) |
| `nativeThreads` | `number` | `4` | CPU threads (native) |
| `nativeContextSize` | `number` | `2048` | Context window (native) |
| `nativeEmbeddingMode` | `boolean` | `false` | Initialize native context in embedding mode |
| `licenseKey` | `string` | — | Commercial license key |
| `autoInit` | `boolean` | `true` | Auto-initialize on mount (React/Vanilla) |

### Useful fields after `initialize()` / `start()`

- `dvai.baseUrl` — URL to hand to an OpenAI SDK (`undefined` under `transport: "none"`)
- `dvai.port` — bound HTTP port (HTTP transport only)
- `dvai.getActiveBackend()` — resolved backend kind
- `dvai.getActiveTransport()` — resolved transport kind

Native platforms expose equivalent fields on their `start()` return value.

---

## Licensing

Dual license:

1. **Development & personal use** — free on `localhost` / `127.0.0.1`.
   The library verifies its own dev context at runtime.
2. **Commercial use** — requires a license key from Deep Voice AI. Contact
   `info@deepvoiceai.co`.

---

## Contributing

`pnpm` monorepo for the JavaScript stack; per-platform repos for native
code. After cloning the JS monorepo:

```bash
pnpm install
pnpm build
pnpm test
```

Create a feature branch, submit a PR. See [`docs/`](./docs/) for
architecture, transports, backends, and per-platform guides.

---

© Deep Voice AI Limited. All rights reserved.
