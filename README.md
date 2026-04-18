![DVAI-Bridge](/assets/banner.png)

# DVAI-Bridge

**DVAI-Bridge** is a high-performance, local-first AI orchestration layer that allows you to run robust LLM agents directly in the browser while maintaining a standard OpenAI-compatible API interface using MSW (Mock Service Worker).

Developed by **Deep Voice Ai Limited**, this library enables privacy-focused, zero-latency AI interactions that work offline and across desktop/mobile environments (including Electron/Capacitor).

---

## 🚀 Key Features

- **Multi-Backend**: Choose between **WebLLM** (MLC/WebGPU) or **Transformers.js** (ONNX/WebGPU/CPU) for maximum model compatibility.
- **Multi-Modal**: Transformers.js backend supports text-generation, text-to-image, ASR, TTS, and more via configurable `pipelineTask`.
- **Local-First**: Runs LLMs entirely in the browser using WebGPU/WebAssembly.
- **OpenAI Compatible**: Exposes a `mockUrl` that behaves exactly like OpenAI's API — works with any agent SDK.
- **Worker Offloaded**: Inference runs in Web Workers to keep the main UI thread responsive.
- **Robust Streaming**: Built-in blank-chunk detection, generation timeout, and engine state recovery.
- **Zero Configuration**: No proxy servers or backend needed for the AI engine.
- **Tree-Shakeable**: Backend-specific dependencies are optional peer deps — install only what you need.
- **TypeScript First**: Full IntelliSense and type safety across all packages.

---

## 📦 Packages

| Package                | Description                                                               |
| ---------------------- | ------------------------------------------------------------------------- |
| `@dvai-bridge/core`    | Core logic: backend engines, MSW orchestration, OpenAI-compatible wrapper |
| `@dvai-bridge/react`   | React Context Provider and `useDvAI` hook                                 |
| `@dvai-bridge/vanilla` | Wrapper for non-framework environments (vanilla JS / CDN)                 |

---

## ⚡ Backend Engines

### WebLLM (Default)

Uses `@mlc-ai/web-llm` — optimized MLC-compiled models running via WebGPU. Best for models specifically compiled for the MLC runtime.

### Transformers.js

Uses `@huggingface/transformers` — runs ONNX models with WebGPU acceleration (auto-falls back to CPU). Supports a much wider range of model architectures and **multiple modalities** (text, image, audio, video).

|                      | WebLLM                | Transformers.js                  |
| -------------------- | --------------------- | -------------------------------- |
| **Model Format**     | MLC-compiled          | ONNX                             |
| **GPU Acceleration** | WebGPU only           | WebGPU or CPU fallback           |
| **Model Variety**    | Limited (MLC catalog) | Huge (HuggingFace Hub)           |
| **Modalities**       | Text only             | Text, Image, Audio, Video        |
| **OpenAI API**       | Built-in              | Custom wrapper (built into DvAI) |

---

## 📥 Installation

### Install only the backend you need:

```bash
# WebLLM only (default)
npm install @dvai-bridge/core @mlc-ai/web-llm

# Transformers.js only
npm install @dvai-bridge/core @huggingface/transformers

# Both backends
npm install @dvai-bridge/core @mlc-ai/web-llm @huggingface/transformers

# With React
npm install @dvai-bridge/react

# With Vanilla JS
npm install @dvai-bridge/vanilla
```

### As a Git Submodule

If you want to include DVAI-Bridge as a git submodule in your project:

1. Add the submodule:
   ```bash
   git submodule add https://github.com/westenets/dvai-bridge.git packages/dvai-bridge
   ```
2. Install dependencies:
   ```bash
   cd packages/dvai-bridge
   pnpm install
   pnpm build
   ```
3. Link the core package in your main project's `package.json`:
   ```json
   "dependencies": {
     "@dvai-bridge/core": "file:./packages/dvai-bridge/packages/dvai-bridge-core"
   }
   ```

### Initialize Workers

DVAI-Bridge needs worker files in your project's `public` directory to function. You can use the built-in CLI to set this up automatically.

**If installed via npm:**

```bash
npx dvai-bridge init [public-dir]
```

**If used as a submodule:**

```bash
node packages/dvai-bridge/packages/dvai-bridge-core/bin/dvai-bridge.js init [public-dir]
```

This command will:

1. Initialize the **MSW service worker** (`mockServiceWorker.js`).
2. Copy the **AI inference workers** (`dvai-transformers.worker.js`, etc.) to your public directory.

---

## 💻 Usage

### React Integration

```tsx
import { DvAIProvider, useDvAI } from "@dvai-bridge/react";

function App() {
	return (
		<DvAIProvider
			config={{
				// WebLLM (default)
				modelId: "gemma-2-2b-it-q4f16_1-MLC",
				licenseKey: "dvai-your-key-here",

				// Or use Transformers.js:
				// backend: "transformers",
				// transformersModelId: "onnx-community/gemma-3n-E2B-it-ONNX",
				// device: "auto", // "webgpu" | "cpu" | "auto"
			}}
		>
			<ChatComponent />
		</DvAIProvider>
	);
}

function ChatComponent() {
	const { isReady, progress, mockUrl, backend } = useDvAI();

	if (!isReady)
		return (
			<div>
				Loading ({backend}): {progress.text}
			</div>
		);

	return (
		<div>
			Local AI is live at {mockUrl} via {backend}
		</div>
	);
}
```

### Vanilla JS / CDN

```html
<script src="https://cdn.jsdelivr.net/npm/@dvai-bridge/vanilla/dist/index.global.js"></script>
<script>
	const ai = new VanillaDvAI({
		// backend: "transformers",
		// transformersModelId: "onnx-community/gemma-3n-E2B-it-ONNX",
	});
	ai.initialize().then(() => {
		console.log("Mock API is active!");
	});
</script>
```

### Direct Inference (No MSW)

```typescript
import { DvAI } from "@dvai-bridge/core";

const ai = new DvAI({
	backend: "transformers",
	transformersModelId: "onnx-community/gemma-3n-E2B-it-ONNX",
});
await ai.initialize();

const response = await ai.chatCompletion({
	messages: [{ role: "user", content: "Hello!" }],
	max_tokens: 100,
});
console.log(response.choices[0].message.content);
```

### Multi-Modal Pipeline (Transformers.js only)

```typescript
import { DvAI } from "@dvai-bridge/core";

// Text-to-Image
const imageAI = new DvAI({
	backend: "transformers",
	transformersModelId: "Xenova/stable-diffusion-v1-4",
	pipelineTask: "text-to-image",
});
await imageAI.initialize();
const result = await imageAI.runPipeline("A cute cat in space");

// Speech-to-Text
const asrAI = new DvAI({
	backend: "transformers",
	transformersModelId: "Xenova/whisper-tiny.en",
	pipelineTask: "automatic-speech-recognition",
});
await asrAI.initialize();
const transcript = await asrAI.runPipeline(audioBuffer);
```

---

## 🛡️ Robustness Features

- **Blank Chunk Detection**: Aborts streaming after too many blank chunks (configurable `maxBlankChunks`, default: 20).
- **Generation Timeout**: Prevents infinite loops (configurable `generationTimeout`, default: 60s).
- **Engine State Recovery**: Resets engine after failures to prevent cascading errors.
- **Finish Reason Checks**: Terminates streams on `"stop"` or `"length"`.
- **Worker Offloading**: Inference runs in Web Workers; gracefully falls back to main thread.

---

## 🔋 Resource Management (Mobile & Laptop)

### React

```tsx
const { unload, init } = useDvAI();
await unload(); // Free resources
await init(); // Re-initialize later
```

### Vanilla JS

```javascript
await ai.unload(); // Free resources
await ai.initialize(); // Re-initialize
```

---

## ⚙️ Configuration Reference

| Option                  | Type                          | Default                                          | Description                              |
| ----------------------- | ----------------------------- | ------------------------------------------------ | ---------------------------------------- |
| `modelId`               | `string`                      | `"gemma-2-2b-it-q4f16_1-MLC"`                    | WebLLM model ID                          |
| `backend`               | `"webllm" \| "transformers"`  | `"webllm"`                                       | Backend engine to use                    |
| `transformersModelId`   | `string`                      | `"onnx-community/gemma-3n-E2B-it-ONNX"`          | HuggingFace model ID                     |
| `pipelineTask`          | `string`                      | `"text-generation"`                              | Transformers.js pipeline task            |
| `device`                | `"webgpu" \| "cpu" \| "auto"` | `"auto"`                                         | Transformers.js device                   |
| `generationTimeout`     | `number`                      | `60000`                                          | Max generation time (ms)                 |
| `maxBlankChunks`        | `number`                      | `20`                                             | Blank chunks before abort                |
| `mockUrl`               | `string`                      | `"https://api.openai.local/v1/chat/completions"` | MSW intercept URL                        |
| `serviceWorkerUrl`      | `string`                      | `"/mockServiceWorker.js"`                        | Path to MSW worker                       |
| `webllmWorkerUrl`       | `string`                      | `"/dvai-webllm.worker.js"`                       | Path to WebLLM inference worker          |
| `transformersWorkerUrl` | `string`                      | `"/dvai-transformers.worker.js"`                 | Path to Transformers.js inference worker |
| `licenseKey`            | `string`                      | —                                                | License key for production               |
| `autoInit`              | `boolean`                     | `true`                                           | Auto-initialize on mount                 |

---

## 🔑 License Activation

DVAI-Bridge is free for development on `localhost` and `127.0.0.1`. In production, the `LicenseValidator` checks for valid signed keys.

1. **Mobile Production**: Detects native `DEBUG` flags in Capacitor and Cordova.
2. **Setup**: Pass your key in the `licenseKey` property.
3. **Get a Key**: Contact `info@deepvoiceai.co` for commercial licensing.

---

## 📜 Licensing

This project is licensed under a **Dual License** model:

1. **Development & Personal Use**: Free to use for development and testing.
2. **Commercial Use**: Requires a paid license from **Deep Voice Ai Limited**.

---

## 🤝 Contributing

We use `pnpm` for monorepo management.

1. Clone the repo: `git clone https://github.com/westenets/dvai-bridge.git`
2. Install dependencies: `pnpm install`
3. Build all packages: `pnpm build`
4. Run tests: `pnpm test`
5. Create a feature branch and submit a PR!

---

© 2026 Deep Voice Ai Limited. All rights reserved.
