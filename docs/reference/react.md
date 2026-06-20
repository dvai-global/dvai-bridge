# React Reference

For React apps. Install `@dvai-bridge/react`.

## `DVAIProvider`

Wraps your tree. Holds the global AI state. Put it at the top — usually
in `main.tsx` or `App.tsx`.

### Props:

- `config`: A [`DVAIConfig`](/reference/api) object.
- `children`: Your React tree.

### Example:

```tsx
import { DVAIProvider } from "@dvai-bridge/react";

<DVAIProvider config={{ backend: "webllm" }}>
	<App />
</DVAIProvider>;
```

---

## `useDVAI` Hook

The main way to talk to the local engine from your components.

### Usage:

```tsx
const { isReady, progress, mockUrl, backend, modelId, unload, init } =
	useDVAI();
```

### Return Properties:

- **`isReady`**: `boolean` — `true` when the engine is up and MSW is intercepting.
- **`progress`**: `{ text: string, progress: number }` — Where the loader is.
- **`mockUrl`**: `string` — The local URL OpenAI clients should hit (default: `https://api.openai.local/v1/chat/completions`).
- **`backend`**: `"webllm" | "transformers" | "native"` — The engine that's running.
- **`modelId`**: `string` — The model that's loaded.
- **`unload()`**: `() => Promise<void>` — Shut the engine down. Free workers and memory.
- **`init()`**: `() => Promise<void>` — Start it up by hand. Use this when you set `autoInit: false`.

---

## LangChain Integration

LangChain works as-is. So does any OpenAI-compatible SDK. DVAI hands
you a local URL — MSW intercepts the `/chat/completions` call and
runs the model on-device.

### Example with Tool Calling:

Small models — Llama 3.2 1B and friends — don't always emit clean
tool-call JSON. Run a manual tool loop. You parse the JSON yourself
and stay in control.

```tsx
import { DVAIProvider, useDVAI } from "@dvai-bridge/react";
import { ChatOpenAI } from "@langchain/openai";
import { DynamicTool } from "langchain";

function App() {
	return (
		<DVAIProvider
			config={{
				backend: "transformers",
				transformersModelId: "onnx-community/Llama-3.2-1B-Instruct-ONNX",
				pipelineTask: "text-generation",
				dtype: "q4",
				device: "auto",
			}}
		>
			<AgentDemo />
		</DVAIProvider>
	);
}

function AgentDemo() {
	const { isReady } = useDVAI();

	const runAgent = async () => {
		if (!isReady) return;

		// MSW intercepts this — no network request leaves the browser
		const model = new ChatOpenAI({
			apiKey: "not-needed",
			configuration: { baseURL: "https://api.openai.local/v1" },
			temperature: 0,
		});

		const tools = {
			get_weather: new DynamicTool({
				name: "get_weather",
				description: "Returns the current weather.",
				func: async () => "Sunny, 25C",
			}),
		};

		let messages = [
			{
				role: "system",
				content:
					'You are a helpful assistant. To use a tool, respond with JSON: {"tool": "name", "args": {}}',
			},
			{ role: "user", content: "What's the weather?" },
		];

		// Manual loop for robust tool-calling on small models
		for (let i = 0; i < 5; i++) {
			const response = await model.invoke(messages);
			const content = (response.content as string).trim();

			if (content.startsWith("{") && content.includes('"tool"')) {
				const toolCall = JSON.parse(content);
				if (tools[toolCall.tool]) {
					const result = await tools[toolCall.tool].func(
						JSON.stringify(toolCall.args),
					);
					messages.push({ role: "assistant", content });
					messages.push({ role: "user", content: `TOOL_RESULT: ${result}` });
					continue;
				}
			}

			console.log("Final Answer:", content);
			break;
		}
	};

	return <button onClick={runAgent}>Run AI Agent</button>;
}
```

### Example with Custom Model (Gemma 4):

Some models — Gemma 4, multimodal stacks — need a `createPipeline`
factory. Pass it through the provider config.

```tsx
import { DVAIProvider, useDVAI } from "@dvai-bridge/react";
import { ChatOpenAI } from "@langchain/openai";
import type { CreatePipelineFn } from "@dvai-bridge/core";

const createGemma4: CreatePipelineFn = async (transformers, ctx) => {
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
};

function App() {
	return (
		<DVAIProvider
			config={{
				backend: "transformers",
				transformersModelId: "onnx-community/gemma-4-E2B-it-ONNX",
				pipelineTask: "image-text-to-text",
				dtype: "q4f16",
				device: "webgpu",
				transformersWorkerUrl: "",
				createPipeline: createGemma4,
			}}
		>
			<Chat />
		</DVAIProvider>
	);
}

function Chat() {
	const { isReady } = useDVAI();

	const ask = async () => {
		if (!isReady) return;

		const model = new ChatOpenAI({
			apiKey: "not-needed",
			configuration: { baseURL: "https://api.openai.local/v1" },
		});

		const response = await model.invoke([
			{ role: "user", content: "Explain quantum computing in 3 sentences." },
		]);
		console.log(response.content);
	};

	return (
		<button onClick={ask} disabled={!isReady}>
			Ask Gemma 4
		</button>
	);
}
```

---

## `dvai` Instance

Need to drop below the hook? The raw `DVAI` core instance is on the
return value too.

```tsx
import { useDVAI } from "@dvai-bridge/react";

const { dvai } = useDVAI();
// Direct access to dvai.chatCompletion(), dvai.runPipeline(), etc.
```
