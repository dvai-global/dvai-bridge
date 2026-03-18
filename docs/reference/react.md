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

## `dvai` Instance

For advanced use cases, the `DvAI` core instance is also exported:

```tsx
import { useDvAI } from '@dvai-edge/react';

const { dvai } = useDvAI();
// Call dvai.chatCompletion() directly if needed
```
