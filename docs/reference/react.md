# React Reference

Integration for React applications using `@dvai-bridge/react`.

## `DvAIProvider`

The provider component that manages the global AI orchestration state. Ensure this wraps your application (usually in `main.tsx` or `App.tsx`).

### Props:
- `config`: A [`DvAIConfig`](/reference/api) object.
- `children`: Your React application components.

### Example:
```tsx
import { DvAIProvider } from '@dvai-bridge/react';

<DvAIProvider config={{ backend: 'webllm' }}>
  <App />
</DvAIProvider>
```

---

## `useDvAI` Hook

The primary interface for interacting with the local AI engine.

### Usage:
```tsx
const { 
  isReady, 
  progress, 
  mockUrl, 
  backend, 
  modelId, 
  unload, 
  init 
} = useDvAI();
```

### Return Properties:

- **`isReady`**: `boolean` — `true` when the engine is fully initialized and MSW is active.
- **`progress`**: `{ text: string, progress: number }` — Current loading/downloading state.
- **`mockUrl`**: `string` — The local URL that intercepts OpenAI-compatible requests (default: `https://api.openai.local/v1/chat/completions`).
- **`backend`**: `"webllm" | "transformers" | "native"` — The currently active inference engine.
- **`modelId`**: `string` — The ID of the currently loaded model.
- **`unload()`**: `() => Promise<void>` — Manually unload the current engine and workers to free resources.
- **`init()`**: `() => Promise<void>` — Manually trigger initialization if `autoInit` was `false`.

---

## LangChain Integration

`dvai-bridge` is fully compatible with LangChain (and other OpenAI-compatible SDKs). It provides a local mock URL that intercepts standard `/chat/completions` requests via MSW (Mock Service Worker).

### Example with Tool Calling:

For small models like Llama 3.2 1B, it is recommended to use a manual tool-execution loop to ensure reliable parsing of JSON-formatted tool calls from the model's message content.

```tsx
import { DvAIProvider, useDvAI } from '@dvai-bridge/react';
import { ChatOpenAI } from "@langchain/openai";
import { DynamicTool } from "langchain";

function App() {
  return (
    <DvAIProvider config={{
      backend: "transformers",
      transformersModelId: "onnx-community/Llama-3.2-1B-Instruct-ONNX",
      pipelineTask: "text-generation",
      dtype: "q4",
      device: "auto",
    }}>
      <AgentDemo />
    </DvAIProvider>
  );
}

function AgentDemo() {
  const { isReady } = useDvAI();

  const runAgent = async () => {
    if (!isReady) return;

    // MSW intercepts this — no network request leaves the browser
    const model = new ChatOpenAI({
      apiKey: "not-needed",
      configuration: { baseURL: "https://api.openai.local/v1" },
      temperature: 0,
    });

    const tools = {
      get_weather: new DynamicTool({
        name: "get_weather",
        description: "Returns the current weather.",
        func: async () => "Sunny, 25C",
      }),
    };

    let messages = [
      { role: "system", content: "You are a helpful assistant. To use a tool, respond with JSON: {\"tool\": \"name\", \"args\": {}}" },
      { role: "user", content: "What's the weather?" }
    ];

    // Manual loop for robust tool-calling on small models
    for (let i = 0; i < 5; i++) {
      const response = await model.invoke(messages);
      const content = (response.content as string).trim();

      if (content.startsWith("{") && content.includes('"tool"')) {
        const toolCall = JSON.parse(content);
        if (tools[toolCall.tool]) {
          const result = await tools[toolCall.tool].func(JSON.stringify(toolCall.args));
          messages.push({ role: "assistant", content });
          messages.push({ role: "user", content: `TOOL_RESULT: ${result}` });
          continue;
        }
      }
      
      console.log("Final Answer:", content);
      break;
    }
  };

  return <button onClick={runAgent}>Run AI Agent</button>;
}
```

### Example with Custom Model (Gemma 4):

When using a model that requires `createPipeline`, pass it through the provider config:

```tsx
import { DvAIProvider, useDvAI } from '@dvai-bridge/react';
import { ChatOpenAI } from "@langchain/openai";
import type { CreatePipelineFn } from "@dvai-bridge/core";

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

function App() {
  return (
    <DvAIProvider config={{
      backend: "transformers",
      transformersModelId: "onnx-community/gemma-4-E2B-it-ONNX",
      pipelineTask: "image-text-to-text",
      dtype: "q4f16",
      device: "webgpu",
      transformersWorkerUrl: "",
      createPipeline: createGemma4,
    }}>
      <Chat />
    </DvAIProvider>
  );
}

function Chat() {
  const { isReady } = useDvAI();

  const ask = async () => {
    if (!isReady) return;

    const model = new ChatOpenAI({
      apiKey: "not-needed",
      configuration: { baseURL: "https://api.openai.local/v1" },
    });

    const response = await model.invoke([
      { role: "user", content: "Explain quantum computing in 3 sentences." }
    ]);
    console.log(response.content);
  };

  return <button onClick={ask} disabled={!isReady}>Ask Gemma 4</button>;
}
```

---

## `dvai` Instance

For advanced use cases, the `DvAI` core instance is also exported:

```tsx
import { useDvAI } from '@dvai-bridge/react';

const { dvai } = useDvAI();
// Direct access to dvai.chatCompletion(), dvai.runPipeline(), etc.
```
