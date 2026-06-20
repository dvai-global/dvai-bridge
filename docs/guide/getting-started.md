# Get started

DVAI-Bridge runs an OpenAI-compatible local server inside your app. You
call `initialize()`, you read `dvai.baseUrl`, you point any OpenAI SDK at
it. No cloud calls. No install for your users.

## The five-minute version

```bash
pnpm add @dvai-bridge/core @dvai-bridge/react @huggingface/transformers
```

```tsx
import { DVAIProvider, useDVAI } from "@dvai-bridge/react";

function App() {
  return (
    <DVAIProvider config={{ backend: "auto" }}>
      <Chat />
    </DVAIProvider>
  );
}

function Chat() {
  const { isReady, baseUrl } = useDVAI();
  // Point any OpenAI SDK at `baseUrl` and you're done.
  return <div>AI is {isReady ? "Ready" : "Loading…"}</div>;
}
```

That's the library, end to end. The rest of this page is for the cases
where the React snippet above doesn't match your stack.

::: tip Going to production?
You need a license JWT before the SDK runs outside `localhost`. See
[License setup](./license/) for the per-platform walkthrough.
:::

## Install

Pick the core package, plus the backends you plan to use.

```bash
# Core (web / Node / Electron)
pnpm add @dvai-bridge/core

# Transformers.js v4 — ONNX models from Hugging Face
pnpm add @huggingface/transformers@^4.0.1

# WebLLM — MLC-compiled models
pnpm add @mlc-ai/web-llm

# Native LLM — pick the one for your stack
pnpm add @dvai-bridge/capacitor         # Capacitor hybrid (iOS + Android)
#   SwiftUI / UIKit  → @dvai-bridge/ios
#   Compose / Views  → co.deepvoiceai:dvai-bridge
#   React Native     → @dvai-bridge/react-native    (RN ≥ 0.77, Bridgeless ON)
```

### Framework wrappers

```bash
# React
pnpm add @dvai-bridge/react

# Vanilla JS or non-framework
pnpm add @dvai-bridge/vanilla
```

## First-run setup

Some worker files need to live in your `public/` folder. One command:

```bash
npx dvai-bridge init ./public
```

That copies:

- `mockServiceWorker.js` — intercepts fetch calls in the browser.
- `dvai-webllm.worker.js` — offloads WebLLM inference.
- `dvai-transformers.worker.js` — offloads Transformers.js inference.

## Use it

### React

Wrap your app with `DVAIProvider`. Read `useDVAI()` anywhere.

```tsx
import { DVAIProvider, useDVAI } from "@dvai-bridge/react";

function App() {
  return (
    <DVAIProvider
      config={{
        backend: "auto", // Native on mobile, WebLLM on web
        nativeModelPath: "public/models/mistral-7b-v0.1.Q4_K_M.gguf",
        modelId: "gemma-2-2b-it-q4f16_1-MLC",
      }}
    >
      <MyChat />
    </DVAIProvider>
  );
}

function MyChat() {
  const { isReady, mockUrl } = useDVAI();
  // mockUrl works with any OpenAI client — LangChain, Vercel AI SDK, raw fetch.
  return <div>AI is {isReady ? "Ready" : "Loading…"}</div>;
}
```

### Vanilla JS

```javascript
import { VanillaDVAI } from "@dvai-bridge/vanilla";

const ai = new VanillaDVAI({
  backend: "webllm",
  modelId: "gemma-2-2b-it-q4f16_1-MLC",
});

await ai.initialize();
console.log("API intercepted at:", ai.mockUrl);
```

### Core package directly

For Next.js, custom workers, or any non-framework setup.

```typescript
import { DVAI } from "@dvai-bridge/core";
import { ChatOpenAI } from "@langchain/openai";

const dvai = new DVAI({
  backend: "transformers",
  transformersModelId: "onnx-community/Llama-3.2-1B-Instruct-ONNX",
  pipelineTask: "text-generation",
  dtype: "q4",
  device: "auto",
});

await dvai.initialize();

const model = new ChatOpenAI({
  apiKey: "not-needed",
  configuration: { baseURL: "https://api.openai.local/v1" },
});

const response = await model.invoke([
  { role: "user", content: "Summarize the key benefits of local AI." },
]);
```

### Custom models

For models the built-in `pipeline()` doesn't cover — multimodal LLMs,
exotic processor signatures — supply a `createPipeline` callback.

```typescript
import { DVAI, type CreatePipelineFn } from "@dvai-bridge/core";

const createGemma4: CreatePipelineFn = async (transformers, ctx) => {
  const { AutoProcessor, Gemma4ForConditionalGeneration } = transformers;

  const processor = await AutoProcessor.from_pretrained(ctx.modelId, {
    progress_callback: ctx.onProgress,
  });
  const model = await Gemma4ForConditionalGeneration.from_pretrained(
    ctx.modelId,
    {
      dtype: ctx.dtype,
      device: ctx.device,
      progress_callback: ctx.onProgress,
    },
  );

  return async (messages, options) => {
    const prompt = processor.apply_chat_template(messages, {
      enable_thinking: false,
      add_generation_prompt: true,
    });
    const inputs = await processor(prompt, null, null, {
      add_special_tokens: false,
    });
    const outputs = await model.generate({
      ...inputs,
      max_new_tokens: options?.max_new_tokens ?? 512,
      do_sample: options?.do_sample ?? true,
    });
    const decoded = processor.batch_decode(
      outputs.slice(null, [inputs.input_ids.dims.at(-1), null]),
      { skip_special_tokens: true },
    );
    return [{ generated_text: decoded[0] ?? "" }];
  };
};

const dvai = new DVAI({
  backend: "transformers",
  transformersModelId: "onnx-community/gemma-4-E2B-it-ONNX",
  pipelineTask: "image-text-to-text",
  dtype: "q4f16",
  device: "webgpu",
  transformersWorkerUrl: "",
  createPipeline: createGemma4,
});

await dvai.initialize();
```

Full API reference: [Backends → Custom Pipeline Factory](/guide/backends#custom-pipeline-factory-createpipeline).

## Embeddings

For RAG or semantic search, initialise with a feature-extraction pipeline.
Call `embedding()` directly, or hit `POST /v1/embeddings` like you would
on OpenAI.

```typescript
const dvai = new DVAI({
  backend: "transformers",
  transformersModelId: "Xenova/all-MiniLM-L6-v2",
  pipelineTask: "feature-extraction",
});
await dvai.initialize();

// Direct API
const vectors = await dvai.embedding(["hello world", "another doc"]);
// vectors: number[][]

// Or via any OpenAI client
const res = await fetch("https://api.openai.local/v1/embeddings", {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ input: ["hello world"], model: "any" }),
});
```

On the native llama.cpp backend (Capacitor / iOS / Android / RN), set
`nativeEmbeddingMode: true` (Capacitor / Web) or `embeddingMode: true`
on `StartOptions` (native SDKs), and point `modelPath` at a GGUF
embedding model. Chat and embedding contexts are separate — for both
at once, run two instances.

WebLLM doesn't support embeddings. `/v1/embeddings` returns 400 on WebLLM.

## Node quick-start

`dvai-bridge` runs in plain Node. The library starts an HTTP server on
`127.0.0.1:38883` (with port fallback).

```javascript
import { DVAI } from "@dvai-bridge/core";
import OpenAI from "openai";

const dvai = new DVAI({ backend: "transformers" });
await dvai.initialize();
console.log(dvai.baseUrl); // e.g. "http://127.0.0.1:38883/v1"

const openai = new OpenAI({ baseURL: dvai.baseUrl, apiKey: "ignored" });
const r = await openai.chat.completions.create({
  model: dvai.transformersModelId,
  messages: [{ role: "user", content: "Hello!" }],
});
console.log(r.choices[0].message.content);
```

Any OpenAI client — Node, .NET, Python, Swift, anything — points at
`dvai.baseUrl` the same way.

## Next steps

- [Pick your platform](/guide/license/) — per-SDK setup + license JWT.
- [Backends](/guide/backends) — pick or override the engine.
- [Transports](/guide/transports) — how the HTTP wire actually works on each runtime.
- [How it compares](/guide/comparison) — DVAI-Bridge vs Ollama, LiteLLM, LangChain, and QVAC.
