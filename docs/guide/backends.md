# Backends

DVAI-Bridge supports multiple backend engines for local AI inference. You can choose the one that best fits your model format and performance requirements.

## WebLLM (Default)

The **WebLLM** backend uses `@mlc-ai/web-llm` to run high-performance, MLC-compiled models via WebGPU.

### Best For:

- High-performance text generation in the browser.
- Models explicitly compiled for the MLC runtime (e.g., Llama, Gemma, Vicuna).

### Setup:

Make sure to install the dependency:

```bash
pnpm add @mlc-ai/web-llm
```

### Configuration:

```typescript
const config = {
	backend: "webllm",
	modelId: "gemma-2-2b-it-q4f16_1-MLC",
	webllmWorkerUrl: "/dvai-webllm.worker.js",
};
```

---

## Transformers.js (v4)

The **Transformers.js** backend uses `@huggingface/transformers` (v4.0.1+) to run ONNX models with WebGPU acceleration (with automatic CPU fallback).

### Best For:

- Multi-modal tasks (Text-to-Image, ASR, TTS, Image Segmentation).
- Models from the Hugging Face Hub (thousands of compatible models).
- Environments where WebGPU might not be available (CPU fallback).

### Setup:

```bash
pnpm add @huggingface/transformers@^4.0.1
```

### Configuration (Standard Pipeline):

For models supported by the built-in `pipeline()` API (text-generation, feature-extraction, etc.):

```typescript
const config = {
	backend: "transformers",
	transformersModelId: "onnx-community/Llama-3.2-1B-Instruct-ONNX",
	device: "auto", // "webgpu" | "cpu" | "auto"
	dtype: "q4", // Quantized for speed and memory efficiency
	pipelineTask: "text-generation",
	transformersWorkerUrl: "/dvai-transformers.worker.js", // Optional: run in Web Worker
};
```

> [!TIP]
> **Dealing with "Unknown ArrayValue filter: trim"**: If you encounter this error (common with Llama 3/3.2 models), ensure your input content is a string. `dvai-bridge` automatically flattens structured content blocks (like those from LangChain) into strings to maintain compatibility with the model's Jinja2 templates.

---

### Custom Pipeline Factory (`createPipeline`)

Many newer models (multimodal models like Gemma 4, or any model whose architecture isn't supported by the `pipeline()` API) require direct model loading. Instead of adding every possible model loader to dvai-bridge, the library exposes a **`createPipeline`** callback that lets you control exactly how the model is loaded and how inference runs.

DVAI handles everything else: MSW setup, the OpenAI-compatible endpoint, response formatting, and streaming.

#### When to use `createPipeline`:

- The model's architecture is not supported by `pipeline()` (e.g., `image-text-to-text`, `any-to-any`).
- You need direct control over model loading, processor/tokenizer setup, or generation options.
- You want to use model-specific classes like `Gemma4ForConditionalGeneration`.

#### Example: Gemma 4 E2B (Multimodal)

```typescript
import { DVAI, type CreatePipelineFn } from "@dvai-bridge/core";

const createGemma4Pipeline: CreatePipelineFn = async (transformers, ctx) => {
	const { AutoProcessor, Gemma4ForConditionalGeneration } = transformers;

	// Load model + processor using the HF-recommended approach
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

	// Return a pipeline-compatible callable
	// Must accept (messages, options) and return [{ generated_text: string }]
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
			temperature: options?.temperature ?? 1.0,
			top_p: options?.top_p ?? 0.95,
			do_sample: options?.do_sample ?? true,
		});
		const promptLength = inputs.input_ids.dims.at(-1);
		const generatedTokens = outputs.slice(null, [promptLength, null]);
		const decoded = processor.batch_decode(generatedTokens, {
			skip_special_tokens: true,
		});
		return [{ generated_text: decoded[0] ?? "" }];
	};
};

const dvai = new DVAI({
	backend: "transformers",
	transformersModelId: "onnx-community/gemma-4-E2B-it-ONNX",
	pipelineTask: "image-text-to-text",
	dtype: "q4f16",
	device: "webgpu",
	transformersWorkerUrl: "", // Custom pipelines run on main thread
	createPipeline: createGemma4Pipeline,
});

await dvai.initialize();
// MSW is now active at https://api.openai.local/v1 with the following endpoints:
//   POST /chat/completions   — full chat API (streaming + non-streaming)
//   POST /completions        — legacy OpenAI completion (auto-forwards to chat)
//   POST /embeddings         — embeddings (transformers feature-extraction or native embeddingMode)
//   GET  /models             — single-entry list
// Use ChatOpenAI, Vercel AI SDK, or any OpenAI-compatible client
```

#### Example: Custom Text Generation with Tokenizer

For models that work with `AutoTokenizer` but not `AutoProcessor`:

```typescript
const createCustomTextPipeline: CreatePipelineFn = async (
	transformers,
	ctx,
) => {
	const { AutoTokenizer, AutoModelForCausalLM } = transformers;

	const tokenizer = await AutoTokenizer.from_pretrained(ctx.modelId, {
		progress_callback: ctx.onProgress,
	});
	const model = await AutoModelForCausalLM.from_pretrained(ctx.modelId, {
		dtype: ctx.dtype,
		device: ctx.device,
		progress_callback: ctx.onProgress,
	});

	return async (messages, options) => {
		const prompt = tokenizer.apply_chat_template(messages, {
			add_generation_prompt: true,
		});
		const inputs = tokenizer(prompt, { return_tensor: true });
		const outputs = await model.generate({
			...inputs,
			max_new_tokens: options?.max_new_tokens ?? 256,
			do_sample: options?.do_sample ?? false,
		});
		const promptLength = inputs.input_ids.dims.at(-1);
		const decoded = tokenizer.batch_decode(
			outputs.slice(null, [promptLength, null]),
			{ skip_special_tokens: true },
		);
		return [{ generated_text: decoded[0] ?? "" }];
	};
};
```

#### The `CreatePipelineFn` Signature

```typescript
type CreatePipelineFn = (
	transformers: any, // The dynamically-imported @huggingface/transformers module
	ctx: {
		modelId: string; // The configured transformersModelId
		device: "webgpu" | "wasm"; // The resolved device
		dtype?: string; // The configured quantization (e.g. "q4f16")
		onProgress?: (info: any) => void; // Progress callback for downloads
	},
) => Promise<PipelineCallable>;

type PipelineCallable = (messages: any, options?: any) => Promise<any>;
```

> [!IMPORTANT]
> When using `createPipeline`, set `transformersWorkerUrl: ""` to skip the built-in Web Worker. Custom pipelines run on the main thread, but WebGPU compute is async so the UI won't block. The built-in worker only works with standard `pipeline()` models.

---

### Multi-Modal Examples (Standard Pipeline):

```typescript
// For non-text tasks supported by pipeline(), use runPipeline() directly
const result = await ai.runPipeline(
	"A professional photograph of a futuristic city",
);
```

---

## Performance References

DVAI-Bridge adds an OpenAI-compatible surface + MSW interception on top of each backend — the raw inference speed is whatever the underlying engine delivers. Numbers are heavily hardware- and model-dependent; rather than republish them, here are the upstream sources:

- **WebLLM** — [WebLLM benchmarks](https://webllm.mlc.ai/#chat-demo) publish tokens/sec for common MLC-compiled models on WebGPU (e.g., Llama 3.1 8B Q4 ≈ 41 tok/s and Phi 3.5 mini ≈ 71 tok/s on an M3 Max, ~71–80% of native speed).
- **Transformers.js** — HuggingFace maintains an official [transformers.js-benchmarking toolkit](https://github.com/huggingface/transformers.js-benchmarking) for WASM / WebGPU / WebNN / Node. Representative numbers are in the [v3 launch post](https://huggingface.co/blog/transformersjs-v3) (e.g., up to ~64× WebGPU-vs-WASM speedup on embeddings; `all-MiniLM-L6-v2` at 8–12 ms/inference on an M2 Air).
- **llama.cpp (native backend via `llama-cpp-capacitor`)** — [`llama-bench`](https://github.com/ggerganov/llama.cpp/tree/master/examples/llama-bench) is the standard tool for per-device prompt-processing and text-generation throughput; results vary widely across CPUs and mobile GPUs (Metal / Vulkan).

To measure the bridge's own overhead (MSW roundtrip, worker postMessage, streaming adapter), compare `dvai.chatCompletion(...)` to a `fetch(mockUrl, ...)` call of the same prompt — they should differ by a few ms at most on modern browsers.
