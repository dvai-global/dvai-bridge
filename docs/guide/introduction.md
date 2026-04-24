# Introduction

**DVAI-Bridge** is a library that embeds a local OpenAI-compatible HTTP
server inside your application — in any major client-development
language, on any major client platform. You import it, call
`initialize()` (or `start()` on native SDKs), and your app exposes the
same OpenAI REST API on loopback that your code would have called in
the cloud. No Ollama install, no backend, no API keys, no cloud
dependency.

## The MOAT

DVAI-Bridge is the only library that lets you point any OpenAI-compatible
client — LangChain, the OpenAI SDK, the Vercel AI SDK, or any
language's OpenAI client — at a real, fully local HTTP endpoint, across:

- **Browser** (React, Vue, Svelte, vanilla JS)
- **Node / Bun**
- **Electron** (main process, with full-native GPU acceleration)
- **Capacitor hybrid mobile** (iOS + Android)
- **Android native** (Kotlin / Java, via AAR)
- **iOS native** (Swift, via Swift Package Manager)
- **.NET desktop** (C#, via NuGet — Windows, macOS, Linux)

Same OpenAI HTTP surface, six language ecosystems, every major platform.
No other project covers this combination.

## The problem

Traditional AI agents rely on cloud APIs (OpenAI, Anthropic), which
introduce three costs that kill many products before they launch:

- **Per-token fees.** Every user query costs money. High-volume apps
  burn through budgets fast.
- **Privacy exposure.** Sensitive data must leave the device. Healthcare,
  legal, finance, and personal-data apps can't accept that.
- **Infrastructure burden.** Managing keys, rate limits, backend servers,
  rotation, secret storage — all for what is conceptually just "run this
  model."

Local inference tooling solves those — until shipping day. Ollama
requires the user to install Ollama. llama.cpp needs a sidecar binary
and lifecycle management. WebLLM and Transformers.js are browser-only.
Every team that has tried to ship a production AI-powered app has
hit this wall.

## The solution

DVAI-Bridge provides a local OpenAI-compatible HTTP server that lives
*inside your app process* on every platform. Three wins for the
developer:

- **Any agent SDK, unmodified.** LangChain, the OpenAI SDK, Vercel AI
  SDK, raw `fetch()` — all work out of the box. Point the `baseURL` at
  `dvai.baseUrl`. Done.
- **Zero per-token costs.** Run indefinitely with no billing limit.
- **Full privacy.** Data is processed entirely on the user's hardware
  (WebGPU, CUDA, Metal, Vulkan, DirectML, CoreML, NNAPI / QNN, etc.,
  whichever is available).

And three wins for the user:

- **Nothing extra to install.** Your app ships with AI built in.
- **Works offline.** Airplane mode, enterprise networks with no outbound
  access — AI still works.
- **No data leaves the device.** Period.

## Technical hurdles it solves

Beyond cost and privacy, DVAI-Bridge solves the fragmentation problem
that kills most attempts at shipping local AI:

- **WebGPU instability.** Automatically detects and recovers from
  browser GPU crashes, re-initializing the engine up to a configurable
  number of times.
- **Resource management.** Clean `unload()` + `init()` hooks for
  battery-aware mobile apps; the model and server are released together.
- **Unified backends.** One API abstracts over WebLLM, Transformers.js,
  llama.cpp, CoreML, MediaPipe LLM, Apple Foundation Models, ONNX
  Runtime GenAI, LiteRT, and more. The agent code never learns which is
  which.
- **Any model architecture.** A declarative loader lets you bring any
  model — even cutting-edge multimodal models — without waiting for
  library updates. See the [Backends guide](/guide/backends).
- **Transport abstraction.** MSW for browsers (intercepts fetch calls),
  real HTTP servers for every other runtime (binds `127.0.0.1`, with
  port-fallback and CORS + Private Network Access headers built in). Same
  handler logic behind both. See the [Transports guide](/guide/transports).

## Key backends

- **WebLLM** — high-performance WebGPU inference for modern browsers
  using MLC-compiled models.
- **Transformers.js (v4+)** — broad compatibility for thousands of ONNX
  models from Hugging Face; text, vision, audio, embeddings. Works in
  browser and Node.
- **Native llama.cpp** — first-party bindings (NAPI / JNI / Swift /
  P/Invoke) over a pinned upstream llama.cpp build. GPU-accelerated on
  every platform (CUDA, Metal, Vulkan, DirectML, Apple Metal).
- **Platform-specific runtimes** — CoreML + Apple Foundation Models on
  iOS; MediaPipe LLM + LiteRT on Android; ONNX Runtime GenAI on .NET.
  Selected per platform based on availability and model format.

## Any model architecture

DVAI-Bridge doesn't maintain a hardcoded list of supported models. Three
paths, in order of preference:

1. **`pipeline()` default** — for standard tasks (text-generation,
   feature-extraction, ASR, etc.), just set `transformersModelId` and
   `pipelineTask`. Thousands of models on the Hugging Face Hub work
   with zero extra config.

2. **[Declarative multimodal loader](/guide/backends#declarative-multimodal-loader)**
   — for models that need named classes like
   `Gemma4ForConditionalGeneration` + `AutoProcessor` (multimodal LLMs,
   vision-language models, speech-to-text with chat), set
   `transformersModelClass` and (optionally)
   `transformersProcessorClass` / `transformersDisableEncoders`. Runs
   in the Web Worker by default — the main thread stays unblocked
   during inference.

3. **[Custom Pipeline Factory](/guide/backends#custom-pipeline-factory-createpipeline)**
   — escape hatch for exotic processor signatures. You supply a factory
   function; DVAI handles the transport, the OpenAI endpoint, streaming,
   and response formatting. Main-thread only.

Cutting-edge multimodal models rarely need option 3. Pick 1 or 2.

## Hybrid backend selection

When configured with `backend: "auto"`, DVAI-Bridge picks the best backend
for the runtime:

1. **Mobile (Capacitor / native iOS / native Android):** native
   llama.cpp with platform-specific acceleration (Metal on iOS; Vulkan
   or NNAPI / QNN on Android).
2. **Electron main / .NET desktop:** native llama.cpp with CUDA / Metal
   / Vulkan / DirectML, whichever is available.
3. **Browser:** WebLLM if WebGPU is present; Transformers.js otherwise.
4. **Node:** Transformers.js or native llama.cpp depending on what's
   installed.

## Transport auto-detection

On `initialize()` or `start()`, DVAI-Bridge picks the right transport:

- **Browser main thread** → MSW intercept (intercepts fetch, no actual
  server process).
- **Node / Electron main / Capacitor mobile / native mobile / .NET desktop**
  → real HTTP server on `127.0.0.1:38883` (with port-fallback up to 16
  attempts).
- **Web Worker / Service Worker** → no transport; use `chatCompletion()`
  directly.

Host applications simply read `dvai.baseUrl` (or the equivalent on each
native SDK) and pass it to any OpenAI SDK. Same API across every
platform. See the [Transports guide](/guide/transports) for details.

## Built-in robustness

If an inference backend fails (blank output, timeout, GPU crash, etc.),
DVAI-Bridge automatically triggers a recovery cycle: unloads the engine,
reloads it, retries the request up to a configurable number of times.
Users don't see a broken UI; they see a brief progress update and then
a valid response.
