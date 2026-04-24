# Introduction

**DVAI-Bridge** is a powerful, local-first AI orchestration library designed to bridge the gap between high-performance LLM inference and the limitations of modern web platforms.

## Why DVAI-Bridge? (The MOAT)

The primary "moat" of **DVAI-Bridge** is its ability to seamlessly bridge high-level **Agent SDKs** (like LangChain, Vercel AI SDK, or LlamaIndex) with **100% local, client-side LLM runtimes**.

### The Problem

Traditional AI agents rely on cloud APIs (OpenAI, Anthropic), which introduces:

- **High Costs**: Every token costs money for the developer and the user.
- **Privacy Gaps**: Sensitive data must leave the device to be processed.
- **Infra Overhead**: Maintaining servers and managing API keys is complex.

### The Solution: Zero-Cost, Local-First Agents

DVAI-Bridge provides a local "Mock API" (via MSW) that behaves exactly like OpenAI. This allows you to:

- **Use Any Agent SDK**: Plug in LangChain, Vercel AI SDK, or raw `fetch()` without changing your agent logic.
- **Zero API Fees**: Run indefinitely without ever hitting a billing limit or paying per-token.
- **Ultimate Privacy**: Data is processed entirely on the user's hardware (WebGPU/Native).

### Solving the Technical Hurdle

Beyond the cost and privacy benefits, DVAI-Bridge solves the fragmentation of local AI:

- **WebGPU Instability**: Automatically detects and recovers from browser crashes.
- **Resource Management**: Polished handlers for loading and unloading models to save battery.
- **Unified Backends**: One API to rule WebLLM, Transformers.js, and Native `llama.cpp`.
- **Any Model Architecture**: The `createPipeline` callback lets you bring any model — even cutting-edge multimodal models — without waiting for library updates.

## Key Backends

- **WebLLM**: High-performance WebGPU inference for modern browsers using MLC-compiled models.
- **Transformers.js (v4)**: Broad compatibility for thousands of ONNX models from Hugging Face — text, vision, audio, embeddings.
- **Native (Capacitor)**: Direct GGUF model execution via `llama-cpp-capacitor` for iOS and Android.

## Any Model Architecture

DVAI-Bridge doesn't maintain a hardcoded list of supported models. Three paths, in order of preference:

1. **`pipeline()` default** — for standard tasks (text-generation, feature-extraction, ASR, etc.), just set `transformersModelId` and `pipelineTask`. Thousands of models on the Hugging Face Hub work with zero extra config.

2. **[Declarative multimodal loader](/guide/backends#declarative-multimodal-loader)** — for models that need named classes like `Gemma4ForConditionalGeneration` + `AutoProcessor` (multimodal LLMs, vision-language models, speech-to-text with chat), set `transformersModelClass` and (optionally) `transformersProcessorClass` / `transformersDisableEncoders`. Runs in the Web Worker by default — the main thread stays unblocked during inference.

3. **[Custom Pipeline Factory](/guide/backends#custom-pipeline-factory-createpipeline)** — escape hatch for exotic processor signatures. You supply a factory function; DVAI handles MSW, the OpenAI endpoint, streaming, and response formatting. Main-thread only.

Cutting-edge multimodal models rarely need option 3. Pick 1 or 2.

## Hybrid Selection

When configured with `backend: "auto"`, DVAI-Bridge follows a smart resolution path:

1. **On Mobile (Capacitor)**: Prioritize the Native backend for performance and stability.
2. **On Web**: Use WebLLM if WebGPU is available, falling back to other configured options.

## Built-in Robustness

If WebLLM fails (e.g., returns a blank output or times out), DVAI-Bridge automatically triggers a recovery cycle: it unloads the engine and reloads it, retrying the request up to a configurable number of times. This ensures your users aren't left with a broken UI.

## Transport Auto-Detection

`DVAI` now auto-selects the right transport for the runtime: MSW in
browsers, a real HTTP server in Node / Electron main, no transport in
Web Workers. Host applications simply read `dvai.baseUrl` and hand it
to any OpenAI SDK — the rest is identical across platforms. See the
[Transports guide](/guide/transports) for details.
