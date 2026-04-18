# Vanilla JS Reference

Direct usage for non-framework environments using `@dvai-bridge/vanilla`.

## `VanillaDVAI` Class

A lightweight wrapper around the core orchestrator, optimized for usage in standard JavaScript environments.

### Usage:

```javascript
import { VanillaDVAI } from "@dvai-bridge/vanilla";

const ai = new VanillaDVAI({
	backend: "webllm",
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

You can also use the core package directly for scenarios where you need full control:

### Standard Pipeline Model:

```javascript
import { DVAI } from "@dvai-bridge/core";

const ai = new DVAI({
	backend: "transformers",
	transformersModelId: "onnx-community/Llama-3.2-1B-Instruct-ONNX",
	pipelineTask: "text-generation",
	dtype: "q4",
	device: "auto",
});

await ai.initialize();

// Option 1: Use the OpenAI-compatible MSW endpoint
const response = await fetch("https://api.openai.local/v1/chat/completions", {
	method: "POST",
	headers: { "Content-Type": "application/json" },
	body: JSON.stringify({
		messages: [{ role: "user", content: "Tell me a joke" }],
		max_tokens: 128,
	}),
});
const data = await response.json();
console.log(data.choices[0].message.content);

// Option 2: Call chatCompletion directly (bypasses MSW)
const result = await ai.chatCompletion({
	messages: [{ role: "user", content: "Tell me a joke" }],
});
```

### Custom Model with `createPipeline`:

```javascript
import { DVAI } from "@dvai-bridge/core";

const ai = new DVAI({
	backend: "transformers",
	transformersModelId: "onnx-community/gemma-4-E2B-it-ONNX",
	pipelineTask: "image-text-to-text",
	dtype: "q4f16",
	device: "webgpu",
	transformersWorkerUrl: "",
	createPipeline: async (transformers, ctx) => {
		const { AutoProcessor, Gemma4ForConditionalGeneration } = transformers;
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
				do_sample: options?.do_sample ?? true,
			});
			const decoded = processor.batch_decode(
				outputs.slice(null, [inputs.input_ids.dims.at(-1), null]),
				{ skip_special_tokens: true },
			);
			return [{ generated_text: decoded[0] ?? "" }];
		};
	},
});

await ai.initialize();
console.log("Gemma 4 ready at:", ai.mockUrl);
```

### MSW Disabled (Direct Pipeline Only):

If you only need `runPipeline()` (e.g., for embeddings) and don't need the OpenAI-compatible endpoint:

```javascript
import { DVAI } from "@dvai-bridge/core";

const embedder = new DVAI({
	backend: "transformers",
	transformersModelId: "Xenova/all-MiniLM-L6-v2",
	pipelineTask: "feature-extraction",
	serviceWorkerUrl: "", // Disable MSW
});

await embedder.initialize();
const embedding = await embedder.runPipeline("Hello world");
```
