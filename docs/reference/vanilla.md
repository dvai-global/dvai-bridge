# Vanilla JS Reference

Direct usage for non-framework environments using `@dvai-edge/vanilla`.

## `VanillaDvAI` Class

A lightweight wrapper around the core orchestrator, optimized for usage in standard JavaScript environments.

### Usage:
```javascript
import { VanillaDvAI } from '@dvai-edge/vanilla';

const ai = new VanillaDvAI({
  backend: 'webllm'
});

await ai.initialize();
```

### Properties:

- **`isReady`**: `boolean` — `true` after successful initialization.
- **`mockUrl`**: `string` — Access the local OpenAI-compatible endpoint.
- **`backend`**: `"webllm" | "transformers" | "native"` — The active inference engine name.
- **`modelId`**: `string` — Resolved model identifier.
- **`progress`**: `{ text: string, progress: number }` — Object tracking loading state.

### Methods:

- **`initialize()`**: `Promise<void>` — Initializes the orchestration layer and starts MSW.
- **`unload()`**: `Promise<void>` — Shuts down the backend and frees all associated RAM/VRAM.
- **`onProgress(callback)`**: `void` — Register a listener for loading progress updates.

---

## Direct Usage (No Wrapper)

You can also use the core package directly for scenarios where MSW is not needed:

```javascript
import { DvAI } from '@dvai-edge/core';

const ai = new DvAI({ backend: 'webllm' });
await ai.initialize();

const result = await ai.chatCompletion({
  messages: [{ role: "user", content: "Tell me a joke" }]
});
```
