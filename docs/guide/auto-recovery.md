# Auto-Recovery & Robustness

Local AI inference can be unpredictable due to varying hardware and memory pressure. DVAI-Bridge includes advanced features to ensure your application remains stable even when the underlying engine fails.

## WebLLM Auto-Recovery

WebLLM (MLC) can sometimes return blank outputs or hang if the WebGPU context is lost or overloaded. DVAI-Bridge implements an automatic recovery cycle for these scenarios.

### Detection Mechanism:

DVAI-Bridge monitors the following as **Fatal Errors**:

- **Blank Output**: The engine returns an empty string for a chat completion.
- **Blank Stream**: A streaming response produces no text content before closing.
- **Timeout**: The generation exceeds the `generationTimeout` (default: 60s).

### Recovery Process:

When a fatal error is detected, DVAI-Bridge:

1.  **Unloads** the current backend (releasing memory and workers).
2.  **Re-initializes** the backend (reloading the model and engine).
3.  **Retries** the original request automatically.

### Configuration:

You can control the recovery behavior via `maxRetries` (default: 2).

```typescript
const config = {
	maxRetries: 3, // Allow up to 3 recovery attempts before giving up
	generationTimeout: 60000, // Timeout in milliseconds
};
```

---

## Blank Chunk Detection

For streaming responses, DVAI-Bridge can abort the generation if it detects too many consecutive empty chunks, which often indicates the model is in an infinite loop or "stuck".

```typescript
const config = {
	maxBlankChunks: 20, // Abort after 20 consecutive empty chunks
};
```

---

## Resource Management

To prevent battery drain and memory leakage, you should unload the model when it's not needed (e.g., when the user navigates away from the chat).

```typescript
// React
const { unload } = useDVAI();
await unload();

// Vanilla
await ai.unload();
```
