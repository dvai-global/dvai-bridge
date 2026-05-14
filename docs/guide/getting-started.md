# Getting started

## What does this do?

DVAI-Bridge runs an OpenAI-compatible local server inside your app.
You call `initialize()`, you read `dvai.baseUrl`, you point any OpenAI
SDK at it. No cloud calls, no install for your users.

If you just want to ship:

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

That's the whole library, end to end. The rest of this page covers
the longer-form options (Vanilla JS, Node, custom models, embeddings)
in case the React snippet above doesn't match your stack.

::: tip Ready to ship to production?
You'll need a license JWT before the SDK runs outside `localhost`.
See [License setup](./license/) for the per-platform walkthrough.
:::

## Installation

Install the core package along with any backends you plan to use.

```bash
# Core package (web / Node / Electron)
pnpm add @dvai-bridge/core

# Transformers.js v4 (for ONNX models from Hugging Face)
pnpm add @huggingface/transformers@^4.0.1

# WebLLM (for MLC-compiled models)
pnpm add @mlc-ai/web-llm

# Native LLM — pick the package that fits your stack:
pnpm add @dvai-bridge/capacitor             # Capacitor hybrid (iOS + Android)
# Or for native apps without Capacitor:
#   - SwiftUI / UIKit  → @dvai-bridge/ios            (see iOS Native SDK guide)
#   - Compose / Views  → co.deepvoiceai:dvai-bridge  (see Android Native SDK guide)
#   - React Native     → @dvai-bridge/react-native   (RN ≥ 0.77, Bridgeless ON)
```

### Framework Wrappers

```bash
# For React projects
pnpm add @dvai-bridge/react

# For Vanilla JS / Non-framework projects
pnpm add @dvai-bridge/vanilla
```

## Initialization

DVAI-Bridge requires certain worker files to be available in your application's `public` folder. You can initialize these automatically:

```bash
npx dvai-bridge init ./public
```

This command copies:

- `mockServiceWorker.js`: For OpenAI-compatible API interception (MSW).
- `dvai-webllm.worker.js`: For WebLLM offloading.
- `dvai-transformers.worker.js`: For Transformers.js offloading.

## Basic Usage

### Using with React

Wrap your app with `DVAIProvider` to initialize the orchestration layer.

```tsx
import { DVAIProvider, useDVAI } from "@dvai-bridge/react";

function App() {
	return (
		<DVAIProvider
			config={{
				backend: "auto", // Automatically selects Native on Mobile, WebLLM on Web
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

	// Use mockUrl with any OpenAI-compatible SDK (LangChain, Vercel AI SDK, etc.)
	return <div>AI is {isReady ? "Ready" : "Loading..."}</div>;
}
```

### Using with Vanilla JS

```javascript
import { VanillaDVAI } from "@dvai-bridge/vanilla";

const ai = new VanillaDVAI({
	backend: "webllm",
	modelId: "gemma-2-2b-it-q4f16_1-MLC",
});

await ai.initialize();
console.log("API intercepted at:", ai.mockUrl);
```

### Using the Core Package Directly

For full control (e.g., in Next.js, custom workers, or non-framework setups):

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

// Connect any OpenAI-compatible client to the local MSW endpoint
const model = new ChatOpenAI({
	apiKey: "not-needed",
	configuration: { baseURL: "https://api.openai.local/v1" },
});

const response = await model.invoke([
	{ role: "user", content: "Summarize the key benefits of local AI." },
]);
```

### Using with Custom Models (createPipeline)

For models not supported by the built-in `pipeline()` API (e.g., Gemma 4, multimodal models), supply a `createPipeline` callback:

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
// MSW is active — connect with LangChain, Vercel AI SDK, or fetch()
```

See the [Backends guide](/guide/backends#custom-pipeline-factory-createpipeline) for the full API reference.

## Generating Embeddings

When you need embeddings (e.g., for RAG), initialize DVAI-Bridge with a feature-extraction pipeline and call `embedding()` directly or hit `POST /v1/embeddings`.

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

// Or via any OpenAI-compatible client
const res = await fetch("https://api.openai.local/v1/embeddings", {
	method: "POST",
	headers: { "Content-Type": "application/json" },
	body: JSON.stringify({ input: ["hello world"], model: "any" }),
});
```

On the **native** llama.cpp backend (Capacitor / iOS / Android / RN), set `nativeEmbeddingMode: true` (Capacitor / Web) or `embeddingMode: true` in `StartOptions` (native SDKs) and point `modelPath` at a GGUF embedding model. The native chat and embedding contexts are distinct — for both, run two backend instances.

**WebLLM does not support embeddings** — `/v1/embeddings` returns 400 on the WebLLM backend.

## Node quick-start

`dvai-bridge` works in plain Node — the library auto-starts an HTTP
server on `127.0.0.1:38883` (with port fallback).

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

Point any OpenAI-compatible SDK (Node, .NET, Python, etc.) at
`dvai.baseUrl` — all talk to the same local endpoint.
