# API Reference

Detailed reference for the `DvAI` configuration and common types.

## `DvAIConfig`

The main configuration object used to initialize the orchestration layer.

| Property                | Type                                               | Default                                          | Description                                                                                                                                              |
| :---------------------- | :------------------------------------------------- | :----------------------------------------------- | :------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `backend`               | `"webllm" \| "transformers" \| "native" \| "auto"` | `"webllm"`                                       | The inference engine to use. Use `"auto"` for intelligent environment selection.                                                                         |
| `modelId`               | `string`                                           | `"gemma-2-2b-it-q4f16_1-MLC"`                    | WebLLM specific model identifier.                                                                                                                        |
| `transformersModelId`   | `string`                                           | `"onnx-community/gemma-3n-E2B-it-ONNX"`          | HuggingFace model ID for Transformers.js.                                                                                                                |
| `pipelineTask`          | `string`                                           | `"text-generation"`                              | Pipeline task for Transformers.js (e.g., `"text-generation"`, `"feature-extraction"`, `"image-text-to-text"`).                                           |
| `device`                | `"webgpu" \| "cpu" \| "auto"`                      | `"auto"`                                         | Device for Transformers.js inference. `"auto"` detects WebGPU availability.                                                                              |
| `dtype`                 | `string`                                           | —                                                | Quantization for Transformers.js models (e.g., `"q4"`, `"q4f16"`, `"q8"`, `"fp16"`).                                                                     |
| `createPipeline`        | `CreatePipelineFn`                                 | —                                                | Custom pipeline factory for models not supported by `pipeline()`. See [Custom Pipeline Factory](/guide/backends#custom-pipeline-factory-createpipeline). |
| `mockUrl`               | `string`                                           | `"https://api.openai.local/v1/chat/completions"` | The URL that MSW intercepts for OpenAI-compatible requests.                                                                                              |
| `serviceWorkerUrl`      | `string`                                           | `"/mockServiceWorker.js"`                        | Path to the MSW service worker script. Set to `""` to disable MSW.                                                                                       |
| `transformersWorkerUrl` | `string`                                           | `"/dvai-transformers.worker.js"`                 | Path to the Transformers.js inference worker. Set to `""` to run on main thread.                                                                         |
| `webllmWorkerUrl`       | `string`                                           | `"/dvai-webllm.worker.js"`                       | Path to the WebLLM inference worker.                                                                                                                     |
| `nativeModelPath`       | `string`                                           | —                                                | Path to the GGUF model file for the Native backend.                                                                                                      |
| `nativeGpuLayers`       | `number`                                           | `99`                                             | Number of layers to offload to GPU in Native backend.                                                                                                    |
| `nativeThreads`         | `number`                                           | `4`                                              | Number of CPU threads for Native inference.                                                                                                              |
| `nativeContextSize`     | `number`                                           | `2048`                                           | Context window size for Native backend.                                                                                                                  |
| `nativeEmbeddingMode`   | `boolean`                                          | `false`                                          | Initialize the native llama.cpp context in embedding mode. Required for `/v1/embeddings` on the native backend.                                          |
| `maxRetries`            | `number`                                           | `2`                                              | Number of automatic recovery attempts on fatal WebLLM errors.                                                                                            |
| `generationTimeout`     | `number`                                           | `60000`                                          | Maximum time (ms) allowed for generation before timing out.                                                                                              |
| `maxBlankChunks`        | `number`                                           | `20`                                             | Abort streaming after this many consecutive empty chunks.                                                                                                |
| `licenseKey`            | `string`                                           | —                                                | Signed key for production environment activation.                                                                                                        |
| `autoInit`              | `boolean`                                          | `true`                                           | Whether to initialize the backend immediately on mount (React only).                                                                                     |

---

## `CreatePipelineFn`

A factory function for custom model loading. Receives the dynamically-imported `@huggingface/transformers` module and a context object. Must return a `PipelineCallable`.

```typescript
type CreatePipelineFn = (
	transformers: any,
	ctx: {
		modelId: string;
		device: "webgpu" | "wasm";
		dtype?: string;
		onProgress?: (info: any) => void;
	},
) => Promise<PipelineCallable>;
```

## `PipelineCallable`

The function returned by `createPipeline`. Accepts chat messages and generation options, returns results matching the Transformers.js pipeline output format.

```typescript
type PipelineCallable = (messages: any, options?: any) => Promise<any>;
// Expected return shape: [{ generated_text: string }]
```

---

## `ChatOptions`

Options passed to `chatCompletion` or `createStreamingResponse`.

| Property      | Type            | Description                                                              |
| :------------ | :-------------- | :----------------------------------------------------------------------- |
| `messages`    | `ChatMessage[]` | Array of `{ role: "user" \| "assistant" \| "system", content: string }`. |
| `stream`      | `boolean`       | Whether to stream the response.                                          |
| `max_tokens`  | `number`        | Maximum number of tokens to generate.                                    |
| `temperature` | `number`        | Sampling temperature (usually 0 to 1).                                   |
| `top_p`       | `number`        | Nucleus sampling threshold.                                              |

---

## `DvAIInstance` (Core Class)

Methods available on the `DvAI` class instance.

### `initialize(onProgress?)`

Initializes the selected backend, starts workers, registers MSW handlers, and begins model downloading/loading. Accepts an optional progress callback.

### `chatCompletion(options)`

Returns a standard OpenAI-format response object. Works for both standard pipeline models and custom `createPipeline` models.

### `createStreamingResponse(options)`

Returns a `ReadableStream` that yields OpenAI-format SSE chunks. On the Transformers.js backend, streaming is real token-level streaming via `TextStreamer` (not word-by-word simulation).

### `embedding(inputs)`

Returns an array of embedding vectors (`number[][]`) for the given string or array of strings.

- `backend: "transformers"` requires `pipelineTask: "feature-extraction"`.
- `backend: "native"` requires `nativeEmbeddingMode: true`.
- Throws when called on the WebLLM backend.

### `runPipeline(inputs, options?)`

Runs the underlying Transformers.js pipeline directly with arbitrary inputs. Use for non-chat tasks (image generation, ASR, etc.).

### `unload()`

Completely unloads the engine and frees memory/workers.

### `getActiveBackend()`

Returns the currently resolved backend instance.

### `getWorker()`

Returns the MSW `SetupWorker` instance (if MSW is active).

---

## OpenAI-Compatible Endpoints

DVAI-Bridge registers MSW handlers for these endpoints, derived from `mockUrl` (defaults to `https://api.openai.local/v1/chat/completions`). If `mockUrl` ends with `/chat/completions`, the base URL is its parent; siblings are registered as:

| Method | Endpoint               | Notes                                                                                                                                                                                                                      |
| :----- | :--------------------- | :------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `POST` | `/v1/chat/completions` | Full chat API. Streaming supported on all backends.                                                                                                                                                                        |
| `POST` | `/v1/completions`      | Legacy OpenAI completion endpoint. The `prompt` field is wrapped into a single user message and forwarded to `/v1/chat/completions`; the response is rewritten to the legacy `text_completion` shape. Streaming supported. |
| `POST` | `/v1/embeddings`       | Returns embeddings. Gated on backend: `transformers` + `pipelineTask: "feature-extraction"`, or `native` + `nativeEmbeddingMode: true`. Returns `400` on WebLLM.                                                           |
| `GET`  | `/v1/models`           | Returns a single-entry list with the currently loaded model ID.                                                                                                                                                            |
