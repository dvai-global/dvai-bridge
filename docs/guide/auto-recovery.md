# Auto-recovery and robustness

Local inference is unpredictable. Hardware varies. Memory pressure
spikes. The engine sometimes fails. DVAI-Bridge ships built-in recovery
so your app stays up when the model below it doesn't.

## WebLLM auto-recovery

WebLLM (MLC) can return blank output or hang — usually a lost or
overloaded WebGPU context. DVAI-Bridge runs an automatic recovery cycle
when it sees that happen.

### What counts as a fatal error

DVAI-Bridge watches for three signals.

- **Blank output** — the engine returns an empty string for a chat completion.
- **Blank stream** — a streaming response closes without producing text.
- **Timeout** — generation exceeds `generationTimeout` (default: 60s).

### What the recovery does

When a fatal error fires, DVAI-Bridge:

1.  **Unloads** the current backend — releases memory and workers.
2.  **Re-initializes** the backend — reloads the model and engine.
3.  **Retries** the original request automatically.

### Configuration

Control the retry budget via `maxRetries` (default: 2).

```typescript
const config = {
	maxRetries: 3, // Allow up to 3 recovery attempts before giving up
	generationTimeout: 60000, // Timeout in milliseconds
};
```

---

## Blank chunk detection

On streaming responses, DVAI-Bridge can abort generation if too many
consecutive empty chunks come through. That usually means the model is
stuck in an infinite loop.

```typescript
const config = {
	maxBlankChunks: 20, // Abort after 20 consecutive empty chunks
};
```

---

## Resource management

To save battery and memory, unload the model when you don't need it —
e.g. when the user navigates away from chat.

```typescript
// React
const { unload } = useDVAI();
await unload();

// Vanilla
await ai.unload();
```
