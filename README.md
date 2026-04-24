![DVAI-Bridge](/assets/banner.png)

# DVAI-Bridge

**The local OpenAI server you bundle inside your app.**

Your Electron, mobile, or web app starts a real OpenAI-compatible HTTP server
on `127.0.0.1` — inside its own process, on every platform. Point LangChain,
the OpenAI SDK, the Vercel AI SDK, or any OpenAI-compatible client at it.
No Ollama install. No backend. No API keys. No cloud. Zero cost per token.

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

The same library runs in the browser, Node, Electron, Capacitor mobile, and
(in upcoming phases) native Android / iOS / .NET. The agent code never
changes.

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
of the day per platform.

DVAI-Bridge is that plumbing, packaged as a library. One `initialize()`
call gives you a live local OpenAI endpoint. Every platform. Any language
that speaks HTTP.

---

## Key properties

- **Embedded, not installed.** A library — `import`, `initialize`, done.
  Your end users install nothing extra.
- **OpenAI HTTP is the universal contract.** Your agent code keeps using
  whatever OpenAI SDK it already uses. No special DVAI-Bridge SDK to learn.
- **Runs anywhere your app does.** Browser, Node, Electron main, Capacitor
  iOS/Android today; native Android AAR / iOS SPM / .NET NuGet in phases
  3-4.
- **Transport auto-detection.** Browser → MSW intercept. Node / Electron →
  real `http.createServer` on loopback. No setup code either way. Host
  apps just read `dvai.baseUrl`.
- **Port fallback built in.** Starts at reserved port `38883` and falls
  forward on `EADDRINUSE`. Multi-instance-safe out of the box.
- **Private Network Access ready.** HTTPS pages can call the loopback
  server — CORS + PNA headers on every response.
- **Backend-pluggable.** WebLLM (WebGPU), Transformers.js (ONNX / WebGPU /
  CPU), native llama.cpp (Capacitor today, Electron NAPI next). One
  config switch; no code change in the agent.
- **Multi-modal.** Text, image, audio, video via Transformers.js
  pipelines. Declarative loader for cutting-edge models (Gemma 4,
  LLaVA, Idefics) without waiting for library updates.
- **Streaming-correct.** SSE passthrough, blank-chunk detection,
  generation timeout, automatic engine-state recovery on fatal errors.

---

## Supported platforms

| Stack | Transport | Backends | Status |
|---|---|---|---|
| Browser (React, Vanilla, Vue, Svelte, etc.) | MSW intercept | WebLLM, Transformers.js | **Shipping (v1.6)** |
| Node | HTTP 127.0.0.1 | Transformers.js | **Shipping (v1.6)** |
| Electron (main + renderer) | HTTP 127.0.0.1 | Transformers.js + native llama.cpp (via NAPI) | v1.6 basic / Phase 2 native |
| Capacitor (iOS + Android) | HTTP 127.0.0.1 | Native llama.cpp | Phase 1 |
| React Native | HTTP 127.0.0.1 | Native llama.cpp | Phase 4 |
| Flutter / Dart | FFI → HTTP 127.0.0.1 | Native llama.cpp | Phase 4 |
| Android native (Kotlin / Java, AAR) | HTTP 127.0.0.1 | Native llama.cpp + LiteRT / MediaPipe | Phase 3 |
| iOS native (Swift, SPM) | HTTP 127.0.0.1 | llama.cpp / CoreML / Apple Foundation Models | Phase 3 |
| .NET desktop (NuGet) | HTTP 127.0.0.1 | llama.cpp + ONNX Runtime GenAI + DirectML | Phase 3 |

See [`POSITIONING.md`](./POSITIONING.md) and [`docs/guide/comparison.md`](./docs/guide/comparison.md)
for how DVAI-Bridge compares to Ollama, `llama-server`, WebLLM, and other
local-AI tools.

---

## Packages

| Package | Description |
|---|---|
| `@dvai-bridge/core` | Core library: backend engines, transport abstraction, handler module, OpenAI surface |
| `@dvai-bridge/react` | React Context Provider + `useDVAI` hook |
| `@dvai-bridge/vanilla` | Wrapper for non-framework environments (vanilla JS / CDN) |

Framework wrappers for React Native, Flutter, and native mobile ship in
Phase 3-4.

---

## Installation

Install the core and the backend you need. Peer dependencies — install only
what your app uses:

```bash
# Transformers.js (recommended — works on web and Node, most model variety)
npm install @dvai-bridge/core @huggingface/transformers

# WebLLM (browser only, MLC-compiled models, fastest for supported models)
npm install @dvai-bridge/core @mlc-ai/web-llm

# With React helpers
npm install @dvai-bridge/react

# Vanilla JS / CDN
npm install @dvai-bridge/vanilla
```

### Initialize MSW worker assets (browser only)

For browser apps, copy the MSW service worker and inference workers into
your `public/` directory:

```bash
npx dvai-bridge init [public-dir]
```

Runs once. Not needed for Node / Electron main process — the HTTP transport
doesn't use service workers.

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

### Direct inference (skip the HTTP surface)

If you don't want an HTTP server (e.g. you're inside a Web Worker), pass
`transport: "none"` and call backends directly:

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

### Multi-modal (Transformers.js only)

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
await init();              // later — reload when needed

// Vanilla / Node
await dvai.unload();
await dvai.initialize();
```

---

## Robustness

- **Blank chunk detection** — aborts streaming after too many blanks
  (`maxBlankChunks`, default 20).
- **Generation timeout** — prevents infinite loops (`generationTimeout`,
  default 60 s).
- **Engine state recovery** — resets the backend on fatal WebLLM errors
  and retries up to `maxRetries` (default 2) times.
- **Stream finish-reason checks** — terminates cleanly on `stop` or `length`.
- **Web Worker offloading** — inference runs off the main thread;
  graceful fallback if workers are unavailable.

---

## Configuration reference

| Option | Type | Default | Description |
|---|---|---|---|
| `backend` | `"webllm" \| "transformers" \| "native" \| "auto"` | `"webllm"` | Inference backend. `"auto"` → native on Capacitor, webllm on web. |
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
| `mockUrl` | `string` | `"https://api.openai.local/v1/chat/completions"` | MSW intercept URL (MSW transport only; ignored under HTTP) |
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

### Useful fields after `initialize()`

- `dvai.baseUrl` — URL to hand to an OpenAI SDK (`undefined` under `transport: "none"`)
- `dvai.port` — bound HTTP port (HTTP transport only)
- `dvai.getActiveBackend()` — resolved backend kind
- `dvai.getActiveTransport()` — resolved transport kind

---

## Licensing

Dual license:

1. **Development & personal use** — free on `localhost` / `127.0.0.1`. The
   library verifies its own dev context at runtime.
2. **Commercial use** — requires a license key from Deep Voice AI. Contact
   `info@deepvoiceai.co`.

---

## Contributing

`pnpm` monorepo. After clone:

```bash
pnpm install
pnpm build
pnpm test
```

Create a feature branch, submit a PR. See [`docs/`](./docs/) for
architecture and guides.

---

© 2026 Deep Voice AI Limited. All rights reserved.
