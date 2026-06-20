# Vanilla JS Reference

No framework? Install `@dvai-bridge/vanilla` and go.

## `VanillaDVAI` Class

A thin wrapper around the core. Built for plain JavaScript — no React,
no provider, no hooks.

### Usage:

```javascript
import { VanillaDVAI } from "@dvai-bridge/vanilla";

const ai = new VanillaDVAI({
	backend: "webllm",
});

await ai.initialize();
```

### Properties:

- **`isReady`**: `boolean` — `true` once initialization finishes.
- **`mockUrl`**: `string` — The local OpenAI-shaped endpoint to point clients at.
- **`backend`**: `"webllm" | "transformers" | "native"` — The engine that's running.
- **`modelId`**: `string` — The model that's loaded.
- **`progress`**: `{ text: string, progress: number }` — Where the loader is.

### Methods:

- **`initialize()`**: `Promise<void>` — Boots the engine. Starts MSW.
- **`unload()`**: `Promise<void>` — Shuts the engine down. Frees RAM and VRAM.
- **`onProgress(callback)`**: `void` — Subscribe to loading progress.

---

## Direct Usage (No Wrapper)

Want full control? Skip the wrapper and use the core package directly.

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

// Option 1: Hit the OpenAI-compatible MSW endpoint
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

// Option 2: Call chatCompletion directly — skips MSW
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

Only need `runPipeline()` — for embeddings, say — and don't care about
the OpenAI endpoint? Turn MSW off.

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
