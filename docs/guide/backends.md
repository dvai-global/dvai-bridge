# Backends

DvAI-Edge supports multiple backend engines for local AI inference. You can choose the one that best fits your model format and performance requirements.

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
  webllmWorkerUrl: "/dvai-webllm.worker.js"
};
```

---

## Transformers.js (v4)

The **Transformers.js** backend uses `@huggingface/transformers` to run ONNX models with WebGPU acceleration (with automatic CPU fallback).

### Best For:
- Multi-modal tasks (Text-to-Image, ASR, TTS, Image Segmentation).
- Models from the Hugging Face Hub (thousands of compatible models).
- Environments where WebGPU might not be available (CPU fallback).

### Setup:
```bash
pnpm add @huggingface/transformers
```

### Configuration:
```typescript
const config = {
  backend: "transformers",
  transformersModelId: "onnx-community/gemma-3n-E2B-it-ONNX",
  device: "auto", // "webgpu" | "cpu" | "auto"
  pipelineTask: "text-generation"
};
```

### Multi-Modal Examples:
```typescript
// For non-text tasks, use the `runPipeline` method directly
const result = await ai.runPipeline("A professional photograph of a futuristic city");
```
