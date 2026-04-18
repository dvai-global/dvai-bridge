# Getting Started

Follow these steps to integrate DvAI-Bridge into your project.

## Installation

Install the core package along with any backends you plan to use.

```bash
# Core package
pnpm add @dvai-bridge/core

# Transformers.js v4 (for ONNX models from Hugging Face)
pnpm add @huggingface/transformers@^4.0.1

# WebLLM (for MLC-compiled models)
pnpm add @mlc-ai/web-llm

# Native LLM (for Capacitor/Mobile)
pnpm add llama-cpp-capacitor
```

### Framework Wrappers

```bash
# For React projects
pnpm add @dvai-bridge/react

# For Vanilla JS / Non-framework projects
pnpm add @dvai-bridge/vanilla
```

## Initialization

DvAI-Bridge requires certain worker files to be available in your application's `public` folder. You can initialize these automatically:

```bash
npx dvai-bridge init ./public
```

This command copies:
- `mockServiceWorker.js`: For OpenAI-compatible API interception (MSW).
- `dvai-webllm.worker.js`: For WebLLM offloading.
- `dvai-transformers.worker.js`: For Transformers.js offloading.

## Basic Usage

### Using with React

Wrap your app with `DvAIProvider` to initialize the orchestration layer.

```tsx
import { DvAIProvider, useDvAI } from '@dvai-bridge/react';

function App() {
  return (
    <DvAIProvider config={{ 
      backend: 'auto', // Automatically selects Native on Mobile, WebLLM on Web
      nativeModelPath: 'public/models/mistral-7b-v0.1.Q4_K_M.gguf',
      modelId: 'gemma-2-2b-it-q4f16_1-MLC'
    }}>
      <MyChat />
    </DvAIProvider>
  );
}

function MyChat() {
  const { isReady, mockUrl } = useDvAI();
  
  // Use mockUrl with any OpenAI-compatible SDK (LangChain, Vercel AI SDK, etc.)
  return <div>AI is {isReady ? 'Ready' : 'Loading...'}</div>;
}
```

### Using with Vanilla JS

```javascript
import { VanillaDvAI } from '@dvai-bridge/vanilla';

const ai = new VanillaDvAI({
  backend: 'webllm',
  modelId: 'gemma-2-2b-it-q4f16_1-MLC'
});

await ai.initialize();
console.log('API intercepted at:', ai.mockUrl);
```

### Using the Core Package Directly

For full control (e.g., in Next.js, custom workers, or non-framework setups):

```typescript
import { DvAI } from "@dvai-bridge/core";
import { ChatOpenAI } from "@langchain/openai";

const dvai = new DvAI({
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
  { role: "user", content: "Summarize the key benefits of local AI." }
]);
```

### Using with Custom Models (createPipeline)

For models not supported by the built-in `pipeline()` API (e.g., Gemma 4, multimodal models), supply a `createPipeline` callback:

```typescript
import { DvAI, type CreatePipelineFn } from "@dvai-bridge/core";

const createGemma4: CreatePipelineFn = async (transformers, ctx) => {
  const { AutoProcessor, Gemma4ForConditionalGeneration } = transformers;

  const processor = await AutoProcessor.from_pretrained(ctx.modelId, {
    progress_callback: ctx.onProgress,
  });
  const model = await Gemma4ForConditionalGeneration.from_pretrained(ctx.modelId, {
    dtype: ctx.dtype, device: ctx.device, progress_callback: ctx.onProgress,
  });

  return async (messages, options) => {
    const prompt = processor.apply_chat_template(messages, {
      enable_thinking: false, add_generation_prompt: true,
    });
    const inputs = await processor(prompt, null, null, { add_special_tokens: false });
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

const dvai = new DvAI({
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
