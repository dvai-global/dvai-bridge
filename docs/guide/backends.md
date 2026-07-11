# Backends

## What does this do?

A backend is the engine that actually runs the model. DVAI-Bridge picks
one for you. WebLLM in browsers. llama.cpp on mobile and desktop. The
platform-native runtime — Foundation, CoreML, MLX, MediaPipe, LiteRT,
LiteRT-LM — when you opt in. Most apps never touch this.

Set `backend: "auto"` and ship.

```ts
const dvai = new DVAI({ backend: "auto", modelId: "Llama-3.2-3B-Instruct-Q4_K_M" });
await dvai.initialize();
```

The rest of this page is for when `auto` isn't what you want — you
specifically need WebLLM's MLC compilation, you're loading an exotic
multimodal model, or you're writing the custom-pipeline escape hatch.

::: tip Quick picker
- Browser, just need text generation? → `backend: "webllm"` (or
  `auto`).
- Browser, need Hugging Face ONNX models or multimodal? → `backend:
  "transformers"`.
- Browser, running Gemma 4 E2B/E4B `.litertlm` weights? →
  `backend: "litertlm"` (Google's on-device LLM runtime).
- Node / Electron / desktop? → `backend: "native"` (llama.cpp).
- iOS / Android native? → use the native SDK's `BackendKind` enum
  (`.litertlm` is now cross-platform on both).
:::

## WebLLM (default for browser)

The **WebLLM** backend runs MLC-compiled models over WebGPU via
`@mlc-ai/web-llm`.

### Best for

- Fast text generation in the browser.
- Models compiled for the MLC runtime — Llama, Gemma, Vicuna.

### Setup

Install the dependency.

```bash
pnpm add @mlc-ai/web-llm
```

### Configuration

```typescript
const config = {
	backend: "webllm",
	modelId: "gemma-2-2b-it-q4f16_1-MLC",
	webllmWorkerUrl: "/dvai-webllm.worker.js",
};
```

---

## Transformers.js (v4)

The **Transformers.js** backend runs ONNX models via
`@huggingface/transformers` (v4.0.1+). WebGPU when available — CPU when
not.

### Best for

- Multimodal tasks — text-to-image, ASR, TTS, image segmentation.
- The full Hugging Face Hub catalogue — thousands of models.
- Devices without WebGPU — CPU fallback is automatic.

### Setup

```bash
pnpm add @huggingface/transformers@^4.0.1
```

### Configuration (standard pipeline)

For models the built-in `pipeline()` covers — text-generation,
feature-extraction, and friends.

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
> **Worker thread is the default — keep it that way.** If the worker URL is missing or the script fails to load, dvai-bridge logs a loud error and falls back to the main thread, which WILL block your UI during inference. Run `npx dvai-bridge init` once to copy the worker file into `public/`. Don't override `transformersWorkerUrl: ""` unless you genuinely need main-thread inference.

> [!TIP]
> **"Unknown ArrayValue filter: trim"** — common with Llama 3 / 3.2. The fix is that input content needs to be a string. `dvai-bridge` flattens structured content blocks (like LangChain's) into strings automatically, so the model's Jinja2 templates keep working.

---

### Declarative multimodal loader

Many modern models — Gemma 4, LLaVA, Idefics, Qwen-VL — don't fit the
stock `pipeline()` factory. They load via named model and processor
classes. They take audio and image inputs through the processor's
positional arguments. Hardcoding a detection table per family doesn't
scale.

Instead, dvai-bridge exposes three declarative config fields. They tell
the library which transformers.js classes to load, which processor to
pair them with, and which submodules to null after load. Everything else
— the worker, the OpenAI endpoint, streaming, `runPipeline()` for binary
payloads — just works.

This is the recommended path for multimodal models. It runs in the
worker by default. The main thread stays free. The main-thread fallback
takes the same path, so behaviour is identical regardless of where the
model lands.

#### When to use the declarative loader

- Your model requires a specific `...ForConditionalGeneration` class — not `pipeline()`.
- Your model needs `AutoProcessor` (or similar) for audio, image, or video inputs alongside text.
- You want to null a submodule after load — e.g. drop `vision_encoder` on a voice-only app to reclaim VRAM.
- You want the worker path to handle it — no framework-specific factory code crossing the worker boundary.

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

The generic multimodal callable uses the common
`processor(prompt, images, audio, options)` signature. Pass media as
content parts on the last user message.

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

`runPipeline()` posts the messages to the worker via `postMessage` —
binary payloads like `Float32Array` survive intact. JSON serialization
through MSW would turn them into enumerated object keys and blow up the
tokenizer. Use `runPipeline()` for any call that carries binary content.
Text-only calls can still go through `chatCompletion()` or MSW.

#### The three declarative config fields

| Field                           | Type       | Default          | Description                                                                                                                                                                                          |
| :------------------------------ | :--------- | :--------------- | :--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `transformersModelClass`        | `string`   | —                | Name of a transformers.js export to use as the model class. Loaded via `ClassName.from_pretrained(modelId)`. Enables the declarative loader. Leave unset to use the stock `pipeline()` factory.      |
| `transformersProcessorClass`    | `string`   | `"AutoProcessor"` | Processor class name. Only used when `transformersModelClass` is set.                                                                                                                                |
| `transformersDisableEncoders`   | `string[]` | `[]`             | Model submodule fields to null after load (e.g. `["vision_encoder"]`). Purely declarative — the library walks the list and nulls each field if present. Unknown/absent names are silently ignored.   |

#### Generic by design

The library hardcodes no model-specific knowledge. If transformers.js
exports the class and the processor follows the common
`(prompt, images, audio, options)` signature, it just works. Swapping to
a different multimodal checkpoint tomorrow is three string fields in
config — no library change.

For processors with a non-standard call signature — kwargs-style,
videos-only — drop to the `createPipeline` factory below. That's the
only escape hatch you'll ever need.

---

### Custom pipeline factory (`createPipeline`)

When the declarative loader can't express what your model needs — exotic
processor signatures, bespoke pre/post-processing, a tokenizer-only
setup — pass a factory function. You supply the model loading and
inference logic. dvai-bridge handles MSW, the OpenAI endpoint, response
formatting, and streaming.

> [!IMPORTANT]
> **`createPipeline` is main-thread only.** Function closures can't cross the Worker boundary. If your model needs to run off the main thread, use the **declarative loader** above — that path runs in the worker.

#### When to use `createPipeline`

- The model's processor takes kwargs, or a positional order the generic multimodal callable doesn't match.
- You need `AutoTokenizer` + `AutoModelForCausalLM` with a custom chat-template.
- You want to inject pre/post-processing — a deduplication pass, a custom streamer.

#### Example: tokenizer-based text generation

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

#### The `CreatePipelineFn` signature

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

### Multimodal examples (standard pipeline)

```typescript
// For non-text tasks supported by pipeline(), use runPipeline() directly
const result = await ai.runPipeline(
	"A professional photograph of a futuristic city",
);
```

---

## LiteRT-LM (web)

The **LiteRT-LM** browser backend runs Google's on-device LLM runtime
via `@litert-lm/core`. WebGPU-accelerated. Ships the same `.litertlm`
weight file as the Android and iOS native paths — one artifact, three
platforms.

### Best for

- Serving Gemma 4 E2B / E4B `.litertlm` models in the browser (public
  Apache 2.0 checkpoints on HuggingFace under `litert-community`).
- Sharing weights with your Android or iOS native builds without a
  separate conversion step.

### Setup

```bash
pnpm add @litert-lm/core
```

### Configuration

```typescript
const config = {
  backend: "litertlm",
  litertLmModelUrl:
    "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it-web.litertlm",
};
```

Same `.litertlm` file works on mobile:
`@dvai-bridge/ios-litertlm-core` (SwiftPM) and
`@dvai-bridge/android-litert-core` consume it via LiteRT-LM's Swift and
Kotlin runtimes.

---

## Native backends (mobile + desktop)

The web backends above run inside the browser process. For Capacitor,
native iOS, native Android, and React Native, dvai-bridge ships a
parallel family of **native** backends. They boot a real `127.0.0.1`
HTTP server inside the app and serve the same OpenAI surface. Your agent
code stays the same on every platform.

| Native backend | Engine | Platforms | Model format | Guide |
|---|---|---|---|---|
| **llama.cpp** | `llama.cpp` (Metal / Vulkan / NEON) | iOS, Android, Capacitor, RN | GGUF | [Native LLM (Capacitor)](./native-backend.md), [iOS](./ios-native-sdk.md), [Android](./android-native-sdk.md), [RN](./react-native-sdk.md) |
| **Apple Foundation Models** | `LanguageModelSession` | iOS 26+ (SwiftPM only) | (no file) | [iOS Native SDK](./ios-native-sdk.md#cocoapods-asymmetries) |
| **CoreML** | `MLModel` + `MLState` | iOS 18+ / macOS 15+ | `.mlmodelc` / `.mlpackage` | [iOS Native SDK](./ios-native-sdk.md) |
| **MLX** | `mlx-swift-lm` (Metal + ANE) | Apple Silicon, iOS 17+ (SwiftPM only) | HuggingFace Hub id | [MLX Backend guide](./mlx-backend.md) |
| **MediaPipe** | LiteRT-LM (post-Phase 3B runtime swap) | Android | `.task` / `.litertlm` | [Android Native SDK § MediaPipe](./android-native-sdk.md#mediapipe-backendkindmediapipe) |
| **LiteRT** | Bare LiteRT 2.x (TFLite successor) | Android | `.tflite` / `.litertlm` | [Android Native SDK § LiteRT](./android-native-sdk.md#litert-backendkindlitert) |
| **LiteRT-LM** | `google-ai-edge/LiteRT-LM` (cross-platform on-device LLM runtime) | iOS 17+, macOS 14+, Android, Capacitor, RN, Flutter, browser | `.litertlm` | [iOS Native SDK § LiteRT-LM](./ios-native-sdk.md), [Android Native SDK § LiteRT](./android-native-sdk.md#litert-backendkindlitert) |

Two notes worth calling out.

- The Android **MediaPipe** backend moved from the deprecated
  `com.google.mediapipe:tasks-genai` SDK to
  `com.google.ai.edge.litertlm:litertlm-android` in v2.0 (Phase 3B).
  Same handler behaviour. Same Capacitor JS contract. The swap is
  invisible to JS callers and to the `MediaPipe` enum case on the
  Android Native SDK.
- The Android **LiteRT** backend (new in v2.1) is distinct from the
  bundled-task MediaPipe wrapper. It runs Llama-style stateful
  `.tflite` / `.litertlm` checkpoints directly on `CompiledModel` with
  a pure-Kotlin `tokenizer.json` BPE parser. SentencePiece and Unigram
  tokenizers are not supported — Gemma users should pick the
  `MediaPipe` backend instead.

For the per-backend modality matrix — text, image, audio, embeddings —
see [Multimodal](./multimodal.md).

---

## Performance references

DVAI-Bridge adds an OpenAI-compatible surface and MSW interception on
top of each backend. Raw inference speed is whatever the underlying
engine delivers. Numbers vary widely with hardware and model — rather
than republish them, here are the upstream sources.

- **WebLLM** — [WebLLM benchmarks](https://webllm.mlc.ai/#chat-demo) publish tokens/sec for common MLC-compiled models on WebGPU (e.g., Llama 3.1 8B Q4 ≈ 41 tok/s and Phi 3.5 mini ≈ 71 tok/s on an M3 Max, ~71–80% of native speed).
- **Transformers.js** — HuggingFace maintains an official [transformers.js-benchmarking toolkit](https://github.com/huggingface/transformers.js-benchmarking) for WASM / WebGPU / WebNN / Node. Representative numbers are in the [v3 launch post](https://huggingface.co/blog/transformersjs-v3) (e.g., up to ~64× WebGPU-vs-WASM speedup on embeddings; `all-MiniLM-L6-v2` at 8–12 ms/inference on an M2 Air).
- **llama.cpp (native backend across `@dvai-bridge/capacitor-llama` / `@dvai-bridge/ios` / `@dvai-bridge/android` / `@dvai-bridge/react-native`)** — [`llama-bench`](https://github.com/ggerganov/llama.cpp/tree/master/examples/llama-bench) is the standard tool for per-device prompt-processing and text-generation throughput; results vary widely across CPUs and mobile GPUs (Metal / Vulkan).

To measure the bridge's own overhead — MSW roundtrip, worker
postMessage, streaming adapter — compare `dvai.chatCompletion(...)` to
a `fetch(mockUrl, ...)` call of the same prompt. On modern browsers
they should differ by a few ms at most.
