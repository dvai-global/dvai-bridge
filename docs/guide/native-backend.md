# Native LLM (Capacitor)

The **Native** backend enables direct GGUF model execution on mobile devices (iOS and Android) using the `llama-cpp-capacitor` plugin. This bypasses WebGPU limitations on mobile and provides significant performance improvements.

## Prerequisites

To use the native backend, your project must be a **Capacitor** application.

### Installation:
```bash
pnpm add llama-cpp-capacitor
```

> [!NOTE]
> You may need to build the native binaries for your target platform (Android Studio or Xcode) after installing the plugin.

## Configuration

When using the native backend, you must provide the path to your GGUF model file.

```typescript
const config = {
  backend: "native", // Or "auto" for automatic detection
  nativeModelPath: "public/models/mistral-7b-v0.1.Q4_K_M.gguf",
  nativeGpuLayers: 20, // Optional: Number of layers to offload to GPU
  nativeThreads: 4,     // Optional: Number of CPU threads to use
  nativeContextSize: 2048 // Optional: Context window size
};
```

## Automatic Detection

By setting `backend: "auto"`, DvAI-Bridge will automatically detect the environment:
- If running as a **Native App (Capacitor)**, it will prioritize the Native backend.
- If running in a **Web Browser**, it will fall back to WebLLM or Transformers.js.

## Model Management

Native models are often large. We recommend placing them in your application's `public/models` folder or using a custom download manager to fetch them to the device's local storage.

---

## Why use Native?

1. **Stability**: Direct integration with the hardware avoids WebGPU driver issues.
2. **Performance**: Optimized C++ execution via `llama.cpp`.
3. **Compatibility**: Supports the widely popular GGUF model format.
4. **Memory Control**: More granular control over memory offloading and thread usage.
