# API Reference

Detailed reference for the `DvAI` configuration and common types.

## `DvAIConfig`

The main configuration object used to initialize the orchestration layer.

| Property | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `backend` | `"webllm" \| "transformers" \| "native" \| "auto"` | `"webllm"` | The inference engine to use. Use `"auto"` for intelligent environment selection. |
| `modelId` | `string` | `"gemma-2-2b-it-q4f16_1-MLC"` | WebLLM specific model identifier. |
| `transformersModelId` | `string` | `"onnx-community/gemma-3n-E2B-it-ONNX"` | HuggingFace model ID for Transformers.js. |
| `nativeModelPath` | `string` | — | Path to the GGUF model file for the Native backend. |
| `nativeGpuLayers` | `number` | `0` | Number of layers to offload to GPU in Native backend. |
| `nativeThreads` | `number` | `4` | Number of CPU threads for Native inference. |
| `nativeContextSize` | `number` | `2048` | Context window size for Native backend. |
| `maxRetries` | `number` | `2` | Number of automatic recovery attempts on fatal WebLLM errors. |
| `generationTimeout` | `number` | `60000` | Maximum time allowed for generation before timing out. |
| `maxBlankChunks` | `number` | `20` | Abort streaming after this many consecutive empty chunks. |
| `licenseKey` | `string` | — | Signed key for production environment activation. |
| `autoInit` | `boolean` | `true` | Whether to initialize the backend immediately on mount (React only). |

---

## `ChatOptions`

Options passed to `chatCompletion` or `createStreamingResponse`.

| Property | Type | Description |
| :--- | :--- | :--- |
| `messages` | `ChatMessage[]` | Array of `{ role: "user" | "assistant" | "system", content: string }`. |
| `stream` | `boolean` | Whether to stream the response. |
| `max_tokens` | `number` | Maximum number of tokens to generate. |
| `temperature` | `number` | Sampling temperature (usually 0 to 1). |
| `top_p` | `number` | Nucleus sampling threshold. |

---

## `DvAIInstance` (Core Class)

Methods available on the `DvAI` class instance.

### `initialize()`
Initializes the selected backend, starts workers, and begins model downloading/loading.

### `chatCompletion(options)`
Returns a standard OpenAI-format response object.

### `createStreamingResponse(options)`
Returns a `ReadableStream` that yields OpenAI-format SSE chunks.

### `unload()`
Completely unloads the engine and frees memory/workers.

### `getActiveBackend()`
Returns the currently resolved backend instance.
