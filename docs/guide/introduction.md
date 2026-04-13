# Introduction

**DvAI-Edge** is a powerful, local-first AI orchestration library designed to bridge the gap between high-performance LLM inference and the limitations of modern web platforms.

## Why DvAI-Edge? (The MOAT)

The primary "moat" of **DvAI-Edge** is its ability to seamlessly bridge high-level **Agent SDKs** (like LangChain, Vercel AI SDK, or LlamaIndex) with **100% local, client-side LLM runtimes**.

### The Problem
Traditional AI agents rely on cloud APIs (OpenAI, Anthropic), which introduces:
- **High Costs**: Every token costs money for the developer and the user.
- **Privacy Gaps**: Sensitive data must leave the device to be processed.
- **Infra Overhead**: Maintaining servers and managing API keys is complex.

### The Solution: Zero-Cost, Local-First Agents
DvAI-Edge provides a local "Mock API" (via MSW) that behaves exactly like OpenAI. This allows you to:
- **Use Any Agent SDK**: Plug in LangChain, Vercel AI SDK, or raw `fetch()` without changing your agent logic.
- **Zero API Fees**: Run indefinitely without ever hitting a billing limit or paying per-token.
- **Ultimate Privacy**: Data is processed entirely on the user's hardware (WebGPU/Native).

### Solving the Technical Hurdle
Beyond the cost and privacy benefits, DvAI-Edge solves the fragmentation of local AI:
- **WebGPU Instability**: Automatically detects and recovers from browser crashes.
- **Resource Management**: Polished handlers for loading and unloading models to save battery.
- **Unified Backends**: One API to rule WebLLM, Transformers.js, and Native `llama.cpp`.
- **Any Model Architecture**: The `createPipeline` callback lets you bring any model — even cutting-edge multimodal models — without waiting for library updates.


## Key Backends

- **WebLLM**: High-performance WebGPU inference for modern browsers using MLC-compiled models.
- **Transformers.js (v4)**: Broad compatibility for thousands of ONNX models from Hugging Face — text, vision, audio, embeddings.
- **Native (Capacitor)**: Direct GGUF model execution via `llama-cpp-capacitor` for iOS and Android.

## Custom Pipeline Factory

For models not supported by the built-in `pipeline()` API (e.g., Gemma 4, multimodal architectures, or future model formats), DvAI-Edge exposes a `createPipeline` callback. You supply the model loading and inference logic; DvAI handles MSW, the OpenAI endpoint, streaming, and response formatting. See the [Backends guide](/guide/backends#custom-pipeline-factory-createpipeline) for details.

## Hybrid Selection

When configured with `backend: "auto"`, DvAI-Edge follows a smart resolution path:
1. **On Mobile (Capacitor)**: Prioritize the Native backend for performance and stability.
2. **On Web**: Use WebLLM if WebGPU is available, falling back to other configured options.

## Built-in Robustness

If WebLLM fails (e.g., returns a blank output or times out), DvAI-Edge automatically triggers a recovery cycle: it unloads the engine and reloads it, retrying the request up to a configurable number of times. This ensures your users aren't left with a broken UI.
