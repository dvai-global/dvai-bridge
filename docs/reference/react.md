# React Reference

Integration for React applications using `@dvai-edge/react`.

## `DvAIProvider`

The provider component that manages the global AI orchestration state. Ensure this wraps your application (usually in `main.tsx` or `App.tsx`).

### Props:
- `config`: A [`DvAIConfig`](/reference/api) object.
- `children`: Your React application components.

### Example:
```tsx
import { DvAIProvider } from '@dvai-edge/react';

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
- **`mockUrl`**: `string` — The local URL that intercepts OpenAI-compatible requests.
- **`backend`**: `"webllm" | "transformers" | "native"` — The currently active inference engine.
- **`modelId`**: `string` — The ID of the currently loaded model.
- **`unload()`**: `() => Promise<void>` — Manually unload the current engine and workers to free resources.
- **`init()`**: `() => Promise<void>` — Manually trigger initialization if `autoInit` was `false`.

---

## LangChain Integration

`dvai-edge` is fully compatible with LangChain (and other OpenAI-compatible SDKs). It provides a local mock URL that intercepts standard `/chat/completions` requests.

### Example with Tool Calling:

For small models like Llama 3.2 1B, it is recommended to use a manual tool-execution loop to ensure reliable parsing of JSON-formatted tool calls from the model's message content.

```tsx
import { useDvAI } from '@dvai-edge/react';
import { ChatOpenAI } from "@langchain/openai";
import { DynamicTool } from "langchain";

function App() {
  const { isReady, mockUrl } = useDvAI();

  const runAgent = async () => {
    if (!isReady) return;

    const model = new ChatOpenAI({
      configuration: { baseURL: mockUrl },
      temperature: 0,
    });

    const tools = {
      get_weather: new DynamicTool({
        name: "get_weather",
        description: "Returns the current weather.",
        func: async () => "Sunny, 25°C",
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

---

## `dvai` Instance

For advanced use cases, the `DvAI` core instance is also exported:

```tsx
import { useDvAI } from '@dvai-edge/react';

const { dvai } = useDvAI();
// Call dvai.chatCompletion() directly if needed
```
