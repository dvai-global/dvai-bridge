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
	// Worker is the default. `transformersWorkerUrl` resolves to
	// "/dvai-transformers.worker.js" automatically; only override if you
	// moved the worker file or have a reason to disable it.
};
```

> [!IMPORTANT]
> **Worker thread is the default, and the library tries hard to keep it that way.** If the worker URL is missing or the script fails to load, dvai-bridge logs a loud error and falls back to running on the main thread — which WILL block your UI during inference. Run `npx dvai-bridge init` once to copy the worker file into your `public/`, and don't override `transformersWorkerUrl: ""` unless you genuinely need main-thread inference.

> [!TIP]
> **Dealing with "Unknown ArrayValue filter: trim"**: If you encounter this error (common with Llama 3/3.2 models), ensure your input content is a string. `dvai-bridge` automatically flattens structured content blocks (like those from LangChain) into strings to maintain compatibility with the model's Jinja2 templates.

---

### Declarative Multimodal Loader

Many modern models (Gemma 4, LLaVA, Idefics, Qwen-VL, etc.) don't fit the stock `pipeline()` factory — they expect to be loaded via named model and processor classes, with audio / image inputs passed through the processor's positional arguments. Instead of hardcoding a detection table per model family, dvai-bridge exposes three declarative config fields that tell the library **which transformers.js classes to load, which processor to pair them with, and which submodules to null after load**. Everything else — the worker, the OpenAI endpoint, streaming, `runPipeline()` for binary payloads — just works.

This is the recommended path for multimodal models. It runs in the worker by default (so the main thread stays unblocked) and on the main-thread fallback path too (so behavior is identical regardless of where the model lands).

#### When to use the declarative loader

- Your model requires a specific `...ForConditionalGeneration` class, not `pipeline()`.
- Your model needs `AutoProcessor` (or similar) for audio/image/video inputs alongside text.
- You want to null a specific submodule after load (e.g. drop `vision_encoder` on a voice-only app to reclaim VRAM).
- You want the worker path to handle it — no framework-specific factory code to cross the worker boundary.

#### Example: Gemma 4 E2B (audio + text, voice-only host)

```typescript
import { DVAI } from "@dvai-bridge/core";

const dvai = new DVAI({
	backend: "transformers",
	transformersModelId: "onnx-community/gemma-4-E2B-it-ONNX",
	pipelineTask: "image-text-to-text",
	dtype: "q4f16",
	device: "webgpu",

	// Worker URL — defaults to this value already; shown for clarity.
	// dvai-bridge will use the worker path when the file is deployed.
	transformersWorkerUrl: "/dvai-transformers.worker.js",

	// Declarative loader — dvai-bridge calls
	//   Gemma4ForConditionalGeneration.from_pretrained(modelId, {...})
	//   AutoProcessor.from_pretrained(modelId, {...})
	// and wraps them in a pipeline-shaped callable. Same contract as
	// `pipeline()`, so chatCompletion / streaming / runPipeline all work.
	transformersModelClass: "Gemma4ForConditionalGeneration",
	transformersProcessorClass: "AutoProcessor",

	// Voice-only host app — drop the vision encoder to reclaim ~99 MB of
	// VRAM after the model loads. dvai-bridge stays modality-agnostic;
	// this is YOUR policy about which modalities you care about.
	transformersDisableEncoders: ["vision_encoder"],
});

await dvai.initialize();
```

#### Feeding audio / image inputs

The generic multimodal callable uses the common `processor(prompt, images, audio, options)` call signature. Pass media as content parts on the last user message:

```typescript
// Audio (e.g. Gemma-4 audio transcription + formatting)
const pcm = new Float32Array(/* 16kHz mono audio samples */);

const result = await dvai.runPipeline(
	[
		{ role: "system", content: "You are a helpful assistant." },
		{
			role: "user",
			content: [
				{ type: "text", text: "Transcribe this audio:" },
				{ type: "audio", data: pcm },
			],
		},
	],
	{ max_new_tokens: 1024 },
);
console.log(result[0].generated_text);

// Image content parts use { type: "image", image | url | data }
// and arrive at the processor as the `images` positional arg.
```

`runPipeline()` posts the messages to the worker via `postMessage`, so binary payloads like `Float32Array` survive intact — JSON serialization through MSW would turn them into enumerated object keys and explode the tokenizer. Use `runPipeline()` for any call that carries binary content; text-only calls can still go through `chatCompletion()` / MSW.

#### The three declarative config fields

| Field                           | Type       | Default          | Description                                                                                                                                                                                          |
| :------------------------------ | :--------- | :--------------- | :--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `transformersModelClass`        | `string`   | —                | Name of a transformers.js export to use as the model class. Loaded via `ClassName.from_pretrained(modelId)`. Enables the declarative loader. Leave unset to use the stock `pipeline()` factory.      |
| `transformersProcessorClass`    | `string`   | `"AutoProcessor"` | Processor class name. Only used when `transformersModelClass` is set.                                                                                                                                |
| `transformersDisableEncoders`   | `string[]` | `[]`             | Model submodule fields to null after load (e.g. `["vision_encoder"]`). Purely declarative — the library walks the list and nulls each field if present. Unknown/absent names are silently ignored.   |

#### Generic by design

The library has no hardcoded knowledge of any specific model. If transformers.js exports the class and the processor follows the common `(prompt, images, audio, options)` call signature, it just works. Swapping to a different multimodal checkpoint tomorrow is three string fields in config — no library-side change.

If you hit a model whose processor takes a non-standard call signature (kwargs-style, videos-only, etc.), drop to the `createPipeline` factory below for full control. That's the only escape hatch you'll ever need.

---

### Custom Pipeline Factory (`createPipeline`)

When the declarative loader can't express what your model needs — exotic processor call signatures, bespoke pre/post-processing, a tokenizer-only setup — pass a factory function instead. You supply the model-loading and inference logic; dvai-bridge handles MSW, the OpenAI endpoint, response formatting, and streaming.

> [!IMPORTANT]
> **`createPipeline` is main-thread only.** Function closures can't cross the Worker boundary. If your model needs to run off the main thread, use the **declarative loader** above — that path runs in the worker.

#### When to use `createPipeline`:

- The model's processor takes kwargs or a non-standard positional order that the generic multimodal callable doesn't match.
- You need `AutoTokenizer` + `AutoModelForCausalLM` with custom chat-template handling.
- You want to inject pre/post-processing (e.g. a deduplication pass, a custom streamer).

#### Example: Tokenizer-based text generation

```typescript
import { DVAI, type CreatePipelineFn } from "@dvai-bridge/core";

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

const dvai = new DVAI({
	backend: "transformers",
	transformersModelId: "your-custom-model-id",
	pipelineTask: "text-generation",
	dtype: "q4f16",
	device: "webgpu",
	transformersWorkerUrl: "", // main-thread only when using createPipeline
	createPipeline: createCustomTextPipeline,
});
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

> [!NOTE]
> Set `transformersWorkerUrl: ""` when using `createPipeline` — it skips the worker init. Custom pipelines run on the main thread, but WebGPU compute is async so the UI won't block on GPU work. (CPU/WASM inference on the main thread WILL block — prefer the declarative loader in that case.)

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
