# DVAI-BRIDGE: A Universal Local Inference Layer for Agentic AI on the Client

**Author:** Deep Chakraborty, CTO, Deep Voice AI Limited  
**Affiliation:** Deep Voice AI Limited, 71–75 Shelton Street, Covent Garden, London, WC2H 9JQ, United Kingdom  
**Correspondence:** Deep Voice AI Limited  
**Date:** April 2026  
**Keywords:** edge AI, local inference, WebGPU, llama.cpp, OpenAI API, agentic AI, service worker, mock service worker, on-device LLM, privacy-preserving ML

---

## Abstract

The dominant deployment model for large language models (LLMs) today places inference inside centralized cloud services. For agentic workloads — where a single user request fans out into tens or hundreds of model calls — this architecture creates compounding problems across privacy, cost, latency, and vendor lock-in. We present **DVAI-BRIDGE**, a polyglot SDK family that moves inference to the end-user's device and presents the result as a drop-in replacement for the OpenAI HTTP API. As of v2.4.0, the family spans **six SDKs** — TypeScript (`@dvai-bridge/core`, `@dvai-bridge/react`, `@dvai-bridge/vanilla`), a Capacitor plugin, a native iOS Swift Package, a native Android AAR family, a React Native TurboModule, a Flutter plugin, and a six-package .NET NuGet family — sharing a single OpenAI-compatible HTTP contract over **nine inference backends**: WebLLM, Transformers.js, llama.cpp (across Web/Capacitor/native iOS/native Android/.NET-Desktop), Apple Foundation Models, CoreML, MLX, MediaPipe LLM Inference, LiteRT, ONNX Runtime + GenAI, and ML.NET. The central technical contribution remains the same: a **Mock Service Worker (MSW)** interceptor in the browser, mirrored by an in-process HTTP server in every native SDK, so that any HTTP client pointed at the bridge's `baseUrl` transparently hits the local model instead of the public internet. Because the wire format is unchanged, existing agent SDKs such as LangChain, Vercel AI SDK, CrewAI, and LlamaIndex — and their Swift / Kotlin / Dart / .NET counterparts (Microsoft.SemanticKernel, the OpenAI Swift SDK, OkHttp + Vercel AI SDK on Android, `dart:io` HttpClient on Flutter) — work against DVAI-BRIDGE without code changes. We describe the architecture, the interception mechanism, the auto-recovery state machine that stabilises browser WebGPU failures, and eight integration case studies spanning the family. We then honestly delimit what the library is and is not today, before situating it inside a broader thesis: edge AI is becoming a _peer tier_ to cloud AI, and purpose-built on-device applications such as _DVAI-Connect_ (end-to-end-encrypted meetings with local intelligence) and _LifeStream_ (a longitudinal personal assistant) are only ethically deployable when inference is local.

---

## 1. Introduction

The conventional wisdom for shipping LLM features in 2024–2026 has been "call the cloud." This works well for isolated, stateless prompts, but it frays quickly under three pressures that define agentic enterprise AI:

1. **Privacy and compliance.** Agent workflows tend to pull in the most sensitive context available — user files, meeting transcripts, patient records, internal code. Shipping that context to a third-party endpoint materially expands the data-protection surface that a CISO has to defend. Regulations such as the EU General Data Protection Regulation (GDPR), the Health Insurance Portability and Accountability Act (HIPAA), and the EU AI Act explicitly favour data minimisation and on-device processing where feasible.
2. **Cost.** A single user goal in an agent system typically expands into a tree of model calls (plan, tool-select, observe, reflect, retry, summarise). Each interior node is a billable token round-trip. The economics that make cloud LLMs attractive for a chat UI invert when a bot can spend ten dollars per successful task.
3. **Latency and reliability.** Agent loops are latency-multiplicative: every cloud round-trip is paid N times. Cloud outages compound the same way.

Two further pressures are under-discussed:

4. **Vendor lock-in.** Building on a proprietary API creates a hard dependency on a single vendor's roadmap, pricing, and content policy.
5. **Model over-specification.** A 175B+ generalist model is expensive overkill for narrow enterprise tasks that a 1B–3B specialist can solve. The right architecture is a _pipeline of small specialists_, not a monolithic oracle.

At the same time, three tailwinds now make client-side inference feasible in a way it was not two years ago. **Hardware:** WebGPU has shipped in every major browser; Apple Neural Engine, Qualcomm Hexagon, Intel NPU, and AMD XDNA appear in virtually every new consumer device. **Models:** small specialists such as Llama 3.2 1B, Gemma 2B, and Phi-3-mini approach the 2023-era quality of GPT-3.5 while fitting comfortably in 1–3 GB of VRAM after 4-bit quantisation. **Tooling:** WebLLM, Transformers.js, and llama.cpp now each expose production-grade on-device inference, but under three different APIs, three different build stories, and three different deployment targets.

The gap, then, is not _inference engines_; the gap is an **orchestration layer** that lets a developer write one piece of code and have it run against a local WebGPU engine in the browser, a CUDA/Metal build in an Electron shell, and a GGUF llama.cpp binary on an iOS or Android device — while preserving compatibility with the agent SDKs the ecosystem has already standardised on.

**DVAI-BRIDGE fills that gap.** Concretely, this paper contributes:

- **C1.** A _pluggable driver architecture_ (§3) that unifies three heterogeneous inference engines behind a single TypeScript interface.
- **C2.** An _in-page OpenAI API emulator_ built on MSW + the Service Worker API (§4). Because the emulation happens at the HTTP layer, any OpenAI-compatible SDK works unchanged.
- **C3.** A pragmatic _robustness layer_ — blank-chunk detection, generation timeouts, and a bounded automatic unload-and-reload recovery loop (§5).
- **C4.** A _custom-pipeline factory_ (`createPipeline`) that keeps the library small while extending it to arbitrary Transformers.js-compatible model families.
- **C5.** A _forward vision_ (§8) for how this substrate unlocks privacy-native applications — DVAI-Connect and LifeStream — that are ethically unviable under cloud inference.

The rest of the paper is organised as follows. §2 reviews related systems. §3 describes the architecture. §4 is the central technical contribution: the MSW-based OpenAI-compatibility layer. §5 covers streaming and robustness. §6 reports integration case studies and honestly disclaims what is not yet benchmarked. §7 discusses trade-offs. §8 projects the roadmap. §9 enumerates limitations. §10 concludes.

---

## 2. Background and Related Work

**Server-local inference.** Ollama, LM Studio, vLLM, and standalone llama.cpp deployments all let a user run an LLM on their own hardware. These systems work well for developers but are impractical for end-user distribution: they require the end user (or an IT department) to install a server, bind a port, manage firewalls, and update the model zoo. In a consumer app — say, a browser-based product — asking the user to install a background server is a distribution-killer.

**Browser-local inference.** MLC's _WebLLM_ [WebLLM] compiles models through MLIR/TVM to WebGPU and ships them as WebAssembly, delivering state-of-the-art performance inside a tab. Hugging Face's _Transformers.js_ [TJS] wraps the ONNX Runtime Web and exposes a Python-style `pipeline()` API across an enormous catalogue of ONNX-quantised models, including vision and audio. _ONNX Runtime Web_ [ORT] underlies Transformers.js but is lower-level. Each of these is excellent at its layer but exposes its own idiosyncratic API, and none of them speaks OpenAI.

**Mobile-local inference.** `llama.cpp` [LlamaCpp] has become the de-facto portable C++ runtime for GGUF-format quantised models, with community-maintained iOS (Metal) and Android (Vulkan) bindings. Apple's Core ML and Google's MediaPipe LLM Inference are the platform-native alternatives; MLC-LLM's mobile runtime is another option.

**Cloud APIs as the _de-facto_ agent interface.** OpenAI's Chat Completions API has become a _lingua franca_: LangChain [LC], Vercel AI SDK, CrewAI, LlamaIndex, and a long tail of agent libraries either default to it or offer it as a first-class backend. OpenAI-compatibility has in effect become a standard — one that competing vendors (Together, Groq, Anyscale, DeepInfra, Mistral, Fireworks) deliberately implement.

**The gap we identify.** No existing system combines (a) true client-side inference that spans Web + Desktop + Mobile, (b) OpenAI-wire-compatibility at the HTTP layer, and (c) a _zero-setup_ distribution story — i.e., no install step for the end user beyond opening the app. DVAI-BRIDGE is aimed precisely at this intersection.

---

## 3. System Architecture

![Figure 1 — Layered architecture](paper-assets/fig1-architecture.svg)

### 3.1 Design Goals

DVAI-BRIDGE was written against five concrete goals:

- **G1 — Uniform API across environments.** One TypeScript surface that behaves identically in a browser tab, a desktop Electron shell, and a Capacitor-wrapped mobile app.
- **G2 — Zero end-user setup.** The user should not install anything, run a background server, or touch a config file. If the app opens, inference runs.
- **G3 — Ecosystem compatibility.** Any library that already speaks OpenAI should work with DVAI-BRIDGE by changing only a `baseURL`.
- **G4 — Hardware agnosticism.** Pick the fastest available execution path automatically — WebGPU if present, native llama.cpp if inside Capacitor, else WebAssembly CPU.
- **G5 — Extensibility without library churn.** Adding a new model should not require a new library release.

### 3.2 The Pluggable Driver Abstraction

The core package (`@dvai-bridge/core`, ≈1.9 kLOC) exports a single orchestrator, `DVAI`, which delegates to a driver at runtime (files in `packages/dvai-bridge-core/src/`). The same _driver_ pattern is now replicated, with platform-idiomatic naming, across every SDK in the family — Swift `Backend` protocols on iOS, Kotlin `Backend` interfaces on Android, and `IBackend` on .NET — yielding the family-grouped backend matrix below as of v2.4.0:

| Family | Driver / backend | Model format | Streaming | Target |
|---|---|---|---|---|
| **Web/JS** | WebLLMBackend | MLC-compiled (WebGPU) | True async-iterator | Browser, WebGPU-capable |
| | TransformersBackend | ONNX (Transformers.js v4+) | True token-level via TextStreamer | Browser (WebGPU/WASM), Node |
| | NativeBackend (Capacitor) | GGUF | True token callback | Capacitor iOS/Android |
| **iOS native** | iOS-Llama | GGUF | True token | iOS device + simulator |
| | iOS-CoreML | mlpackage | True token | iOS A14+ |
| | iOS-Foundation | Apple Foundation Models | True token | iOS 18.4+ |
| | iOS-MLX | MLX safetensors | True token | iOS A17+ / M-series |
| **Android native** | Android-Llama | GGUF | True token | Android arm64 |
| | Android-MediaPipe | MediaPipe LLM Inference (.task) | True token | Android |
| | Android-LiteRT | TFLite | True token | Android (Phase 3B-migrated) |
| **.NET (v2.4)** | Desktop-Llama (P/Invoke) | GGUF | True token | win-x64 / linux-x64 / osx-arm64 |
| | .NET-ONNX | ONNX | True token | .NET 10 cross-platform |
| | .NET-MLNet | ONNX (via ML.NET) | Per-call | .NET 10 desktop primary |

![Figure 6 — Platform × backend coverage](paper-assets/fig6-platform-coverage.svg)

Each driver implements the same four-method contract: `initialize(onProgress)`, `chatCompletion(body)`, `createStreamingResponse(body)` → `ReadableStream<Uint8Array>` (or its platform-native equivalent — `AsyncSequence<Data>` on Swift, `Flow<ByteArray>` on Kotlin, `IAsyncEnumerable<ReadOnlyMemory<byte>>` on .NET), and `unload()`. The orchestrator does not know or care which driver is active; it only knows how to plug a driver into the OpenAI-shaped request/response surface described in §4.

### 3.3 Environment Detection and Auto-Selection

![Figure 2 — Backend selection decision tree](paper-assets/fig2-backend-selection.svg)

The configuration surface (`DVAIConfig`) accepts `backend: "webllm" | "transformers" | "native" | "auto"`. When `auto` is chosen, `DVAI.resolveBackend()` (in `packages/dvai-bridge-core/src/index.ts`) performs a two-step decision:

```typescript
private resolveBackend(): "webllm" | "transformers" | "native" {
  if (this.backend === "auto") {
    const isCapacitor =
      typeof window !== "undefined" &&
      !!(window as any).Capacitor?.isNativePlatform?.();
    if (isCapacitor) return "native";
    return "webllm";
  }
  return this.backend as "webllm" | "transformers" | "native";
}
```

That is: if the runtime is a Capacitor-wrapped mobile app, prefer the native GGUF/llama.cpp path; otherwise default to WebLLM. The Transformers.js backend is never chosen by `auto` — it is the _opt-in_ path for multi-modal workloads (image-to-text, ASR, TTS, feature extraction) or for CPU-only fallback.

### 3.4 Configuration and Extensibility

The `DVAIConfig` surface is intentionally small. The main knobs fall into four groups:

- **Backend selection**: `backend`, `modelId`, `transformersModelId`, `pipelineTask`, `device`, `dtype`.
- **Native (Capacitor)**: `nativeModelPath`, `nativeGpuLayers` (default 99), `nativeThreads` (default 4), `nativeContextSize` (default 2048), `nativeEmbeddingMode` (default `false`; set `true` to specialise the llama.cpp context for embeddings).
- **Robustness**: `generationTimeout` (default 60 000 ms), `maxBlankChunks` (default 20), `maxRetries` (default 2).
- **Transport**: `mockUrl` (default `https://api.openai.local/v1/chat/completions`, also used to derive the base URL for `/v1/completions`, `/v1/embeddings`, and `/v1/models`), `serviceWorkerUrl`, per-backend worker URLs.

The extensibility story is carried by `createPipeline`, a factory callback that lets a caller bring any Transformers.js-compatible model — including architectures the library has never heard of (e.g., `Gemma4ForConditionalGeneration` with a custom `AutoProcessor`). DVAI supplies MSW wiring, streaming serialisation, and OpenAI shaping; the caller supplies model loading and the `generate` function. This avoids the anti-pattern in which every new model requires a new library release.

### 3.5 React and Vanilla Wrappers

Two thin wrappers exist on top of the core:

- **`@dvai-bridge/react`** ships a `DVAIProvider` context component and a `useDVAI()` hook that exposes `{ isReady, progress, mockUrl, backend, modelId, init, unload, dvai }`.
- **`@dvai-bridge/vanilla`** wraps the core with a `subscribe(listener)` observable pattern for frameworks (Vue, Svelte, Angular) or vanilla apps.

Both are thin — the core does the work, the wrappers translate state transitions into idioms the framework likes.

Beyond the React + Vanilla wrappers, DVAI-BRIDGE exposes parallel native SDKs that present the same OpenAI HTTP contract from inside their host language: a Capacitor plugin for hybrid mobile, an iOS Swift Package and an Android AAR for native mobile, a React Native TurboModule, a Flutter plugin, and a .NET NuGet family covering iOS + Android (via .NET MAUI), Mac Catalyst, and Windows / macOS / Linux desktop. All seven SDKs share the same handler logic, the same OpenAI endpoint set, and the same backend / state / progress contract. The differences are surface-level — `DVAIProvider` + `useDVAI` on React; `DVAIBridge.shared.start(...)` returning a `BoundServer` on Swift; `DVAIBridge.start(...)` on Kotlin (with a `StateFlow`-driven `reactive` surface for Compose); `DVAIBridge.instance.start(...)` returning a `Stream<DVAIBridgeState>` on Dart; `await DVAIBridge.Shared.StartAsync(...)` exposing an `IAsyncEnumerable<ProgressEvent>` on .NET. The substrate beneath each surface is identical: a per-process HTTP server (or, in the browser, an MSW interceptor) bound to `127.0.0.1:<port>/v1`, listening for the same OpenAI-shaped requests, dispatching to the same backend / state / progress machinery. The interface is what unifies the family; the implementations differ only where the host language idiom demands it.

### 3.6 Backend Reference

The §3.2 driver table is the matrix-at-a-glance view; this subsection answers the per-backend questions a serious adopter will ask: which OS / framework / runtime each backend talks to, which model formats it eats, what model families are known to work, what hardware acceleration it uses, what it gives you, what it costs you, and the decision rule for picking it over a peer. DVAI-BRIDGE is a thin shim above each of these; the heavy lifting belongs to the upstream engine.

**Auto** is not a backend; it is a routing rule (§3.3) that resolves to one of the others at start time. The remaining nine are real engines.

#### 3.6.1 WebLLM (browser-only)

- **Runtime:** `@mlc-ai/web-llm` 0.2.x. MLC's Apache-TVM-compiled engine running in the browser via WebGPU + WebAssembly.
- **Hosts:** Chromium, Firefox, Safari with WebGPU enabled. WebKit Linux behind a flag; iOS Safari is gated on iOS 18+.
- **Model format:** MLC-compiled (`-MLC` suffix on Hugging Face, e.g. `gemma-2-2b-it-q4f16_1-MLC`). A separate compile step is required to produce these artefacts; the catalogue MLC publishes is the practical universe of supported models.
- **Model families known to work:** Llama 2/3, Gemma 1/2/3n, Mistral, Phi-3, Qwen 2, TinyLlama, RedPajama, in q4f16 / q4f32 / q3f16 quantisations. The MLC catalogue is the source of truth.
- **Acceleration:** WebGPU on the GPU; WebAssembly + SIMD as a fallback that DVAI-BRIDGE does **not** automatically pick (WebLLM-without-WebGPU is not viable for our latency target).
- **Pros:** the highest-throughput in-browser path on supported models. True async-iterator streaming. Multimodal prompt caching. No server.
- **Cons:** model catalogue is narrower than Hugging Face's Transformers.js zoo. Compile-step overhead means new model architectures lag the upstream LLM ecosystem by weeks-to-months. WebGPU is still maturing — driver bugs and adapter loss are real (handled by §5.3 recovery). No embeddings (returns HTTP 400; see §4.4 / §9).
- **Pick when:** browser-only, your model is in the MLC catalogue, you want the fastest path on a WebGPU-capable device.

#### 3.6.2 Transformers.js (browser + Node)

- **Runtime:** `@huggingface/transformers` 4.0.1+. Hugging Face's TypeScript port over `onnxruntime-web` (browser) + `onnxruntime-node` (Node).
- **Hosts:** Any modern browser (WebGPU or WASM SIMD); Node 18+; Bun; Deno; Electron renderer.
- **Model format:** ONNX with optional quantised variants (`q4`, `q8`, `f16`, `int8`, `uint8`). The Hugging Face Hub hosts thousands of pre-converted ONNX models under `onnx-community/*`.
- **Model families known to work:** virtually anything with an ONNX export — Llama, Gemma 2/3n, Phi, Qwen, Whisper, CLIP, Stable Diffusion, Florence-2, LLaVA, Idefics, and the long tail. Multimodal pipelines (text+image, ASR, TTS, embeddings, feature-extraction) work via `pipelineTask`.
- **Acceleration:** WebGPU when present; WebNN where exposed; WASM SIMD CPU fallback. Node falls back to native `onnxruntime-node` (CPU + CUDA + DirectML where the host runtime supports them).
- **Pros:** widest catalogue. Multimodal first-class. Same code path runs in browser + Node + Bun + Deno + Electron renderer + service worker (with caveats on the latter). Streaming via `TextStreamer`.
- **Cons:** ONNX runtime is generally slower than MLC-compiled WebGPU at peak; quantisation choices are coarser. Some custom model loaders need `createPipeline` (§3.4 / §6.2). Embeddings supported but require `pipelineTask: "feature-extraction"`.
- **Pick when:** you need the broadest model variety; you need multimodal; you need cross-browser-and-Node parity in one library.

#### 3.6.3 llama.cpp (every non-browser platform)

- **Runtime:** `llama.cpp` upstream (release tag `b8946` pinned), consumed as source + built into our first-party bindings (NAPI, JNI, Swift / C++, P/Invoke).
- **Hosts:** Capacitor (iOS + Android), native iOS, native Android, React Native, Flutter, .NET MAUI on every OS, .NET Desktop on win-x64 / linux-x64 / osx-arm64. Electron via `node-llama-cpp` is supported but not a first-party path here.
- **Model format:** GGUF (`q2_K`, `q3_K_S/M/L`, `q4_0`, `q4_K_S/M`, `q5_K_S/M`, `q6_K`, `q8_0`, `f16`, `f32`). Llama-Context can be specialised at construction for chat or embeddings; not both (§9).
- **Model families known to work:** Llama 1/2/3/3.1/3.2/3.3, Gemma 2/3n, Mistral, Mixtral, Phi-3/3.5, Qwen 2/2.5, Yi, DeepSeek, TinyLlama, StableLM, anything with a GGUF export. Multi-modal mtmd (vision-language) via the `mtmd.xcframework` + matching Android binary on iOS / Android.
- **Acceleration:** Metal on iOS + macOS; Vulkan on Android (when the GPU + driver expose Vulkan compute); CUDA + Metal + Vulkan + DirectML on desktop. CPU fallback via AVX2 / AVX-512 / NEON. `nativeGpuLayers` (default 99) controls the offload split.
- **Pros:** widest deployable surface. Stable runtime — llama.cpp ships weekly, our pin moves on a deliberate cadence. GGUF is the lingua franca of the open-model world; almost every new model gets a GGUF release within hours of weights being public.
- **Cons:** GGUF is a CPU-tilt format — even with full GPU offload, prompt processing is slower than Apple Foundation / CoreML / MLX on equivalent hardware. Memory-mapped loads can be touchy on 32-bit Androids. Tool-calling on small (≤3B) GGUF models needs manual JSON parsing rather than structured `tool_calls` (§6.1).
- **Pick when:** you want the broadest platform reach with one model artefact; you're shipping to mobile + desktop and don't want a per-platform model zoo; you're starting from a model that already has a GGUF release.

#### 3.6.4 Apple Foundation Models (iOS 26+ / iPadOS 26+ / macOS 15+ / visionOS 2+)

- **Runtime:** `LanguageModelSession` from Apple's Foundation Models framework (Swift; no third-party engine). Apple's on-device model only.
- **Hosts:** iOS 26+ via the iOS Swift SDK; Mac Catalyst 26+ via the same SDK; .NET MAUI / Catalyst slices via the iOS binding.
- **Model format:** none. Apple ships the model with the OS; the developer chooses the *task*, not the *model*.
- **Model families known to work:** the Apple-curated model behind `LanguageModelSession`. Apple controls the family + version; consumers do not.
- **Acceleration:** managed entirely by the OS — Apple Neural Engine / Metal as Apple sees fit. Not configurable.
- **Pros:** zero model download. Battery-optimised. Privacy guarantees built into the OS-level entitlement story. Quality is excellent for what Apple ships. Always available on supported hardware (no "model loading" UX).
- **Cons:** iOS 26+ floor (covers ~30% of installed iPhones at the time of writing — grows fast but not yet majority). The model is what Apple gives you — no fine-tuning, no custom prompts at the system level beyond what `LanguageModelSession` exposes. No streaming control beyond what Apple's API offers. No inspection of weights or tokeniser. Foundation Models is a *managed runtime*, not a model you operate.
- **Pick when:** you target iOS 26+ exclusively, you trust Apple's model for your task, you want zero-download UX, you don't need model-side control.

#### 3.6.5 CoreML / Apple Neural Engine (iOS 14+, macOS 11+)

- **Runtime:** Apple's CoreML (`.mlpackage` / `.mlmodelc`) compiled to ANE / GPU / CPU at consumer install time. Wrapped in our iOS Swift SDK.
- **Hosts:** native iOS, .NET MAUI iOS, .NET MAUI Catalyst, Mac Catalyst from .NET 10's binding.
- **Model format:** `.mlpackage` produced by `coremltools`'s `ct.convert(...)` from PyTorch / TensorFlow. Quantisation goes down to 4-bit weight packing (palettisation) on iOS 18+.
- **Model families known to work:** anything you can convert — typically the small specialists (Llama-3.2-1B / 3B, Gemma 2B, Phi-3-mini). Conversion pipeline is non-trivial; Apple's `mlx-lm-conversion` helpers and HuggingFace's `coreml-models` org are starting points.
- **Acceleration:** Apple Neural Engine when the model graph is ANE-compatible; GPU otherwise; CPU as a last-resort. The system decides per op.
- **Pros:** ANE is by far the most power-efficient inference path on iPhones (≈10× efficiency over CPU at typical token rates). Compiled at install time, so app-side latency on first run is low. Stable on iOS 14+.
- **Cons:** the conversion pipeline is the friction point — many models won't convert cleanly, and quality degrades through palettisation more sharply than GGUF q4. No streaming inside CoreML; we synthesise streaming externally. Re-converting on a new model architecture is a real engineering task, not a one-liner.
- **Pick when:** battery efficiency on iPhone is critical; the model is small enough to be ANE-amenable; you can budget for the conversion pipeline.

#### 3.6.6 MLX / mlx-swift-lm (iOS 17+, macOS 14+ Apple Silicon)

- **Runtime:** Apple's `MLX` framework (`mlx-swift-lm`). Apple Silicon-only — runs on the GPU via Metal, with Neural Engine awareness.
- **Hosts:** native iOS A17+ (iPhone 15 Pro / 16+ / 17+), Apple Silicon Mac, Mac Catalyst, .NET MAUI iOS / Catalyst slices.
- **Model format:** MLX `safetensors` (e.g. `mlx-community/Llama-3.2-3B-Instruct-4bit`). HuggingFace's `mlx-community` org maintains a large catalogue.
- **Model families known to work:** Llama 1/2/3/3.2, Gemma 2, Mistral, Phi-3, Qwen 2, with 4-bit / 8-bit MLX-native quantisations.
- **Acceleration:** Metal-direct (no CoreML compile step). MLX is closer to PyTorch's mental model than CoreML and supports KV-cache, beam search, sampling control natively.
- **Pros:** developer ergonomics close to PyTorch (`mlx.array`, `mx.softmax`, etc.). Quantisation that preserves quality better than CoreML palettisation at equivalent bits. Streaming first-class.
- **Cons:** Apple Silicon-only — no x86 Mac, no iPhone 14 or earlier. Less mature than llama.cpp; runtime evolves quickly and APIs occasionally break across versions. Models load from disk uncompiled, so first-token-latency is higher than CoreML's pre-compiled path.
- **Pick when:** your install base is iPhone 15 Pro+ or recent Macs; you want the best-quality 4-bit on Apple Silicon; CoreML conversion isn't worth the friction.

#### 3.6.7 MediaPipe LLM Inference (Android primary; iOS supported)

- **Runtime:** Google's MediaPipe LLM Inference C++ engine, packaged as a `.task` bundle. Supports both transformer LLMs and Gemma-tuned dialog models.
- **Hosts:** Android 26+ via the Android SDK; Phase 3D umbrella + the React Native / Flutter / .NET wrappers. iOS path exists in MediaPipe's roadmap; not yet a first-party DVAI-BRIDGE backend on iOS.
- **Model format:** `.task` bundle (containing model weights + tokenizer + config + sometimes a LoRA adapter). Google publishes pre-converted bundles for Gemma 2B, Falcon 1B, StableLM 3B; community bundles cover Llama 3.2 1B / 3B and Phi-3-mini.
- **Acceleration:** GPU delegate (Vulkan), NNAPI delegate, and Hexagon QNN delegate where the device exposes Qualcomm's HTP. Selection is automatic; the engine probes and falls back.
- **Pros:** on Snapdragon 8-Gen-2+ devices with QNN, this is the highest-throughput path on Android by a meaningful margin. First-party Google support; bundles are stable and tested. Streaming + KV-cache built in.
- **Cons:** model catalogue is small (by design — Google curates). `.task` bundles are 2-4× the size of equivalent GGUF q4. Adding a new model architecture means waiting for Google or producing the bundle yourself (non-trivial). No iOS path today.
- **Pick when:** you target Snapdragon 8 Gen 2+ Android specifically; the bundled model fits your task; you want Google's first-party path over the community llama.cpp build.

#### 3.6.8 LiteRT (Android, every Android API ≥ 24)

- **Runtime:** Google's LiteRT (the TFLite successor). Phase 3B migrated us off the legacy `tensorflow-lite` artefact onto this. Pure-Kotlin BPE tokenizer (no native dep).
- **Hosts:** Android 24+ via the Android SDK; the React Native / Flutter / .NET wrappers transit through it. Not on iOS.
- **Model format:** `.tflite` (FlatBuffer). Hugging Face's `litert-community` org publishes Llama / Gemma / Phi exports.
- **Model families known to work:** Llama 3.2 1B / 3B, Gemma 2B, Phi-3-mini, with int8 / int4 weight-quantised exports.
- **Acceleration:** GPU delegate (OpenGL / OpenCL / Vulkan), NNAPI, Hexagon delegate. Less aggressive than MediaPipe's Hexagon QNN path; LiteRT prioritises portability over peak.
- **Pros:** the broadest Android-API floor of any backend (24+ vs. MediaPipe's 26+). Pure-Kotlin tokenizer means no JNI for token boundaries. Smaller bundle than MediaPipe `.task`. Stable, battle-tested runtime under TFLite-since-2017.
- **Cons:** slower than MediaPipe + QNN on Hexagon-capable devices. Tokenizer surface is hand-rolled in our wrapper rather than vendored from a vetted library — see [`litert-lm-migration-notes.md`](docs/development/litert-lm-migration-notes.md). Model variety is narrower than llama.cpp.
- **Pick when:** you need Android-API-24 support; battery + bundle size matters more than peak throughput; you don't need Hexagon QNN.

#### 3.6.9 ONNX Runtime GenAI (.NET only — every OS)

- **Runtime:** Microsoft's `Microsoft.ML.OnnxRuntime` 1.25.0 + `Microsoft.ML.OnnxRuntimeGenAI` 0.13.1. Cross-platform (.NET 10), but exposed only through the .NET NuGet family in DVAI-BRIDGE today.
- **Hosts:** .NET 10 LTS — Windows / Linux / macOS desktop, .NET MAUI on iOS / Android (with the matching native library), Avalonia, WinUI, console.
- **Model format:** ONNX with the ORT-GenAI `genai_config.json` companion file. Microsoft's `microsoft/Phi-3-mini-4k-instruct-onnx` and the broader HuggingFace ONNX-GenAI org are the canonical sources.
- **Model families known to work:** Phi-3 / 3.5, Llama 2 / 3, Gemma 2, Qwen 2, Mistral. Microsoft tends to optimise heavily for Phi (their own family).
- **Acceleration:** ONNX Runtime execution providers — CUDA, DirectML, CoreML, ROCm, and CPU. The provider is selected by the runtime based on what's installed; DVAI-BRIDGE doesn't override.
- **Pros:** first-party Microsoft path. DirectML on Windows lights up Intel Arc, AMD Radeon, and NVIDIA without a CUDA dependency. CoreML EP gives a serviceable iOS / macOS path inside .NET MAUI. Tokeniser, sampler, KV-cache all bundled.
- **Cons:** model catalogue narrower than GGUF. Memory footprint higher than llama.cpp at equivalent quality on the same machine. Cold-start time noticeably longer (provider probe + graph compile).
- **Pick when:** you're a .NET shop and want a first-party Microsoft path; you target Windows + DirectML where llama.cpp's DirectML backend doesn't yet match peak; you're already invested in ONNX as your model format.

#### 3.6.10 ML.NET (.NET only — desktop primary)

- **Runtime:** Microsoft's `Microsoft.ML` 5.0.0 with `OnnxScoringEstimator`. ML.NET is Microsoft's classical-ML / tabular framework that grew an ONNX scoring path.
- **Hosts:** .NET 10 desktop primarily — Windows / Linux / macOS console, WinUI, Avalonia. Mobile + Catalyst paths technically work but are RAM-tight.
- **Model format:** ONNX, fed through ML.NET's `MLContext.Transforms.ApplyOnnxModel(...)`.
- **Model families known to work:** small classification, regression, and embedding models (sentence-transformers, BERT-class encoders). Generative LLMs through ML.NET are awkward — possible, but not the framework's sweet spot.
- **Acceleration:** ONNX Runtime under the hood; provider selection same as §3.6.9 (CUDA, DirectML, CoreML, CPU).
- **Pros:** for shops already running ML.NET pipelines (an enterprise-tilt audience), the **same** DVAIBridge HTTP API now sits over their existing classification / scoring models. No second framework to learn.
- **Cons:** not a sensible choice for chat-LLM workloads — use §3.6.9 (ONNX Runtime GenAI) for generative work. ML.NET's API surface is verbose for streaming token output.
- **Pick when:** the model you want to expose is a classifier / regressor / encoder, not a generative LLM, and your stack is already ML.NET. Otherwise: don't.

#### 3.6.11 Model-format / framework-pick decision tree (one-page summary)

```
Browser-only?
├─ Model in MLC catalogue?    → WebLLM
└─ Otherwise                  → Transformers.js

iOS app?
├─ iOS 26+ floor + want zero-download? → Foundation Models
├─ Want max battery efficiency, can convert? → CoreML
├─ A17+ install base, want PyTorch-like ergonomics? → MLX
└─ Otherwise (broad iPhone reach, 1 model artefact)  → llama.cpp / GGUF

Android app?
├─ Snapdragon 8-Gen-2+ install base + curated model? → MediaPipe
├─ Need API 24 floor or smaller bundle?              → LiteRT
└─ Otherwise (broad reach, 1 model artefact)         → llama.cpp / GGUF

.NET MAUI?  → routes to the iOS / Android / Catalyst native backends above.

.NET Desktop / WinUI / Avalonia?
├─ DirectML target (Windows GPU, no CUDA)  → ONNX Runtime GenAI
├─ Phi-tilt or Microsoft-ecosystem-tilt    → ONNX Runtime GenAI
├─ Generative LLM, broadest format reach   → llama.cpp Desktop
└─ Classifier / encoder, ML.NET pipeline   → ML.NET

Web + Server in Node?  → Transformers.js (`onnxruntime-node`).
```

The decision tree is intentionally orthogonal to model *quality* — once you've picked a backend, the model choice is whatever your task demands at the quality tier you can afford on that backend. DVAI-BRIDGE's role is to make the surface above the backend identical so the *application* code never has to make that choice.

---

## 4. The OpenAI-Compatibility Layer

This is the library's central contribution, and the mechanism that turns every other architectural decision from "neat" into "useful."

![Figure 3 — Request interception sequence](paper-assets/fig3-request-flow.svg)

### 4.1 Why OpenAI-Compatibility Matters

Agent SDKs are opinionated about wire format. LangChain's `ChatOpenAI`, Vercel AI SDK's `streamText`, CrewAI's tool loops, and most of the long tail of "build an agent" libraries assume an OpenAI-shaped HTTP endpoint serving `/v1/chat/completions` with SSE streaming. Any local-inference library that wants to be _used_ — rather than ported to, one SDK at a time — has to either (a) fork every SDK or (b) serve the agreed wire format. DVAI-BRIDGE chooses (b).

### 4.2 In-Page HTTP Interception via MSW

Mock Service Worker (MSW) [MSW] is a library originally built for API mocking in tests. It registers a real browser Service Worker that intercepts `fetch` calls matching a route pattern and hands them to a user-defined handler. DVAI-BRIDGE repurposes this mechanism for production: during `DVAI.initialize()`, the library registers a handler for its mock URL (default `https://api.openai.local/v1/chat/completions`) and then calls `setupWorker(...).start({ serviceWorker: { url: "/mockServiceWorker.js" }, onUnhandledRequest: "bypass" })`.

The handler (excerpt from `DVAI.buildMswHandlers()` in `packages/dvai-bridge-core/src/index.ts`; one of four handlers, covering `POST /v1/chat/completions`) is terse but does a surprising amount:

```typescript
http.post(this.mockUrl, async ({ request }) => {
	const requestBody = await request.json();
	if (requestBody.stream) {
		const stream = this.backendInstance.createStreamingResponse(requestBody);
		return new HttpResponse(stream, {
			headers: {
				"Content-Type": "text/event-stream",
				"Cache-Control": "no-cache",
				Connection: "keep-alive",
			},
		});
	}
	const response = await this.backendInstance.chatCompletion(requestBody);
	return HttpResponse.json(response);
});
```

Four things are worth noting:

1. **The handler is environment-agnostic.** Whether the active driver is WebLLM, Transformers.js, or Native, the handler's code is unchanged — the driver polymorphism is absorbed by `this.backendInstance`.
2. **The response honours the SSE contract.** Streaming responses carry the standard `text/event-stream` content type, which means the client's SSE parser (from LangChain, the AI SDK, or a hand-written `EventSource`) works verbatim.
3. **Non-browser paths are handled gracefully.** If the code is running inside a Web Worker or if `serviceWorkerUrl` is explicitly empty, MSW setup is skipped and callers are expected to invoke `chatCompletion()`/`createStreamingResponse()` directly on the `DVAI` instance.
4. **The mock URL is itself a configuration knob.** An app can expose its local inference endpoint at any host name, not just `api.openai.local`, and re-point its SDKs accordingly.

### 4.3 Implications

Because the interception happens at the HTTP layer rather than inside a JavaScript binding, the library achieves a rare property: **ecosystem leverage without ecosystem wrapping**. Consider the LangChain case (from the project's reference docs):

```typescript
import { ChatOpenAI } from "@langchain/openai";

const chat = new ChatOpenAI({
	apiKey: "not-needed",
	configuration: { baseURL: "https://api.openai.local/v1" },
});
const reply = await chat.invoke([{ role: "user", content: "Hello!" }]);
```

This is not a DVAI-BRIDGE-specific LangChain adapter. It is _the_ LangChain OpenAI client, unchanged, pointed at the mocked endpoint. Every LangChain feature that works against OpenAI today — streaming, tool calling via downstream SDK logic, structured output, runnable graphs — works against DVAI-BRIDGE too, for free.

### 4.4 What Is and Is Not Implemented Today

The library currently implements four OpenAI endpoints, all registered through the same MSW interceptor and derived from a single `mockUrl`:

- `POST /v1/chat/completions` — the primary endpoint; streaming and non-streaming supported on all three drivers.
- `POST /v1/completions` — the legacy OpenAI text-completion endpoint. The incoming `prompt` is wrapped as a single user message, forwarded to the chat pipeline, and the response is rewritten to the legacy `text_completion` shape. A small SSE adapter rewrites chat chunks to the legacy chunk shape for streaming clients.
- `POST /v1/embeddings` — returns OpenAI-shaped embedding vectors. Gated by backend: supported when `backend: "transformers"` with `pipelineTask: "feature-extraction"`, or when `backend: "native"` with `nativeEmbeddingMode: true`. WebLLM returns HTTP 400 with an explanatory error since MLC runtimes do not currently expose embedding outputs.
- `GET /v1/models` — returns a single-entry list with the currently loaded model ID, matching the OpenAI `list models` response shape.

The remaining OpenAI surface — `/v1/audio/*` and `/v1/images/*` — is explicitly **future work**. These are the two endpoint families that require additional pipeline machinery (ASR/TTS models, image-generation models) that the library does not yet orchestrate through its OpenAI layer; users can, however, reach them today via `DVAI.runPipeline()` on the Transformers.js backend. The roadmap in §8 returns to this.

---

## 5. Streaming and Robustness

### 5.1 Streaming Across Backends

All three drivers expose `createStreamingResponse(body): ReadableStream<Uint8Array>` and serialise to the OpenAI delta-chunk SSE format. Under the hood they differ in mechanism but are now uniformly _true streaming_:

- **`WebLLMBackend`** receives a native async iterator of `ChatCompletionChunk` objects from MLC, wraps it in a `ReadableStream`, and emits each chunk verbatim. Tokens are forwarded as soon as the engine produces them.
- **`NativeBackend`** uses the `llama-cpp-capacitor` per-token callback to push tokens into the stream as they are decoded by llama.cpp.
- **`TransformersBackend`** attaches a `TextStreamer` (from `@huggingface/transformers`) to the underlying pipeline with `skip_prompt: true` and a `callback_function` that forwards each decoded text fragment. In worker mode the callback runs inside the Web Worker and `postMessage`s a `stream_chunk` event per fragment; in main-thread mode it enqueues directly. An earlier implementation generated the full response and then split it on whitespace to _simulate_ streaming — that path has been removed because its time-to-first-token equalled full generation time, defeating the UX purpose of streaming.

With this change, perceived-latency characteristics are now roughly comparable across the three drivers; differences that remain are properties of the underlying engines (WebGPU vs. ONNX Runtime vs. Metal/Vulkan llama.cpp) rather than of DVAI-BRIDGE itself.

### 5.2 Failure Modes in Practice

WebGPU inference in a browser is not mission-critical-software yet. In several months of production use, three fault classes recurred:

- **Blank-output deadlock.** The engine nominally produces tokens, but every delta's `content` field is empty. The stream would never end on its own.
- **Runaway / stuck generation.** The engine produces tokens but never hits a stop sequence, or hangs on a single shader dispatch.
- **Silent engine failure.** The underlying WebGPU adapter is lost (device unplugged, driver crash, tab backgrounded aggressively) and the engine enters an unrecoverable state.

### 5.3 The Auto-Recovery State Machine

![Figure 4 — Auto-recovery state machine](paper-assets/fig4-auto-recovery.svg)

DVAI-BRIDGE addresses all three classes with a single bounded state machine (`DVAI.attemptRecovery()` in `packages/dvai-bridge-core/src/index.ts`):

- A _blank-chunk counter_ is incremented each time the driver emits a chunk with empty `delta.content`; if it exceeds `maxBlankChunks` (default 20), the driver marks `lastFatalError` and aborts.
- A _generation timeout_ (default 60 000 ms) races every streamed iteration; timing out likewise marks `lastFatalError`.
- Any driver error during `createStreamingResponse` or `chatCompletion` raises to the MSW handler.

When the handler detects a fatal error _and_ `recoveryAttempts < maxRetries` (default 2), it executes:

1. `backend.unload()` — release the engine and GPU resources.
2. `initializeBackend()` — rebuild the driver from scratch.
3. `backend.clearFatalError()` — reset the blank-chunk counter.
4. Replay the user's original request on the fresh engine.

If `recoveryAttempts` is exhausted, the handler returns an HTTP 500 to the caller. The state machine therefore caps the _worst-case_ behaviour at `maxRetries + 1` attempts per user request, and there is no unbounded loop. In practice, the single-attempt recovery path clears the vast majority of WebGPU-driver transients.

---

## 6. Evaluation and Case Studies

No published performance benchmarks currently exist for DVAI-BRIDGE. Rather than fabricate numbers, we present qualitative evaluation along three axes — _ecosystem reach_, _extensibility_, and _deployability_ — and then openly disclose what remains to be measured.

### 6.1 Case Study: LangChain Agent Over a Local Model

The essential developer ergonomics claim is that migrating an existing OpenAI-backed agent to DVAI-BRIDGE is a one-line change. Consider a typical LangChain tool-using agent. The _before_ code targets OpenAI:

```typescript
const chat = new ChatOpenAI({ apiKey: process.env.OPENAI_API_KEY });
```

The _after_ code targets DVAI-BRIDGE:

```typescript
const chat = new ChatOpenAI({
	apiKey: "not-needed",
	configuration: { baseURL: "https://api.openai.local/v1" },
});
```

The rest of the agent's graph — tool definitions, prompt templates, runnables, output parsers — is untouched. For small local models, the project's reference documentation recommends a manual JSON-parsing loop on the assistant content rather than the cloud-grade function-calling protocol, because models in the 1–3B range emit tool calls as inline JSON rather than as structured `tool_calls` fields. This is an honest constraint of small-model behaviour, not a library limitation.

### 6.2 Case Study: Custom Pipeline for Gemma 4 Multimodal

Not every Transformers.js-compatible model fits the stock `pipeline()` API — vision-language models in particular often require an `AutoProcessor`, manual input packing, and a non-standard `generate` signature. The `createPipeline` factory lets users bring the full machinery without forking the library:

```typescript
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
		},
	);
	return async (messages, options) => {
		const prompt = processor.apply_chat_template(messages, {
			add_generation_prompt: true,
		});
		const inputs = await processor(prompt, null, null, {
			add_special_tokens: false,
		});
		const outputs = await model.generate({
			...inputs,
			max_new_tokens: options?.max_new_tokens ?? 512,
		});
		const decoded = processor.batch_decode(
			outputs.slice(null, [inputs.input_ids.dims.at(-1), null]),
			{ skip_special_tokens: true },
		);
		return [{ generated_text: decoded[0] ?? "" }];
	};
};
```

Passing `createPipeline: createGemma4` to the config slots the custom loader into the driver. MSW wiring, streaming, and OpenAI shaping are still supplied by DVAI. This pattern has scaled to multimodal families that did not exist when the library was written — a meaningful test of the extensibility goal (G5).

### 6.3 Case Study: Mobile GGUF via Capacitor

On a Capacitor-wrapped iOS or Android app, a single config switches from browser inference to on-device GGUF via `llama-cpp-capacitor`:

```typescript
<DVAIProvider config={{
  backend: "auto",                                    // Capacitor detected → native
  nativeModelPath: "public/models/mistral-7b-Q4_K_M.gguf",
  nativeGpuLayers: 99,
  nativeThreads: 4,
  nativeContextSize: 2048,
}}>
  <MyChat />
</DVAIProvider>
```

The `MyChat` component does not know whether it is being served by WebLLM in Safari or by llama.cpp through Metal on an iPhone. The OpenAI-compatibility layer erases the difference from the application's point of view.

### 6.4 Developer-Ergonomics Diff

A cloud-to-local migration in this architecture involves three touched surfaces: one `baseURL` change, one `api-key` change, and one `<DVAIProvider>` wrap. No tool calls are rewritten. No agent graphs are rebuilt. No streaming parser is re-plumbed. The minimal-friction promise (G3) is kept on the development side.

### 6.6 iOS-Native LangChain via the Swift OpenAI Client

The iOS Swift Package (`@dvai-bridge/ios`, v2.0.0+) lets a SwiftUI / UIKit app start the bridge in-process — without Capacitor — and immediately point the official OpenAI Swift SDK (or the LangChain-Swift port) at the returned `baseUrl`. The integration is a four-line bootstrap plus the SDK call:

```swift
import DVAIBridge

let server = try await DVAIBridge.shared.start(.init(
    backend: .llama,
    modelPath: "/path/to/Llama-3.2-1B-Instruct.Q4_K_M.gguf"
))
let openAI = OpenAI(configuration: .init(token: "local",
    host: server.baseUrl))    // e.g. http://127.0.0.1:38883/v1
let reply = try await openAI.chats(query: .init(messages: [.user("Hi")]))
```

The Swift SDK never knows the backend is local. The same pattern works against `.coreml` / `.foundation` (iOS 26+) / `.mlx` (Apple Silicon) by changing only the `backend` argument; the OpenAI wire contract is invariant. `DVAIBridge.shared.reactive` exposes a `@MainActor`-isolated `ObservableObject` (under SwiftPM) so a SwiftUI view can bind `isReady` / `baseUrl` / `currentBackend` without polling.

### 6.7 Android-Native via OkHttp + Vercel AI SDK in Compose

The Android AAR umbrella (`co.deepvoiceai:dvai-bridge`, v2.1.0+) presents the same `start(...)` → `BoundServer` API in Kotlin, returning a 127.0.0.1 base URL that any HTTP client can hit. The idiomatic Compose pattern uses `viewModelScope` + OkHttp for streaming and a `StateFlow` for UI binding:

```kotlin
val server = DVAIBridge.start(StartOptions(
    backend = BackendKind.Auto,
    modelPath = "/sdcard/Download/Llama-3.2-1B-Instruct-Q4_K_M.gguf",
    contextSize = 2048, threads = 4,
))
val req = Request.Builder()
    .url("${server.baseUrl}/chat/completions")
    .post("""{"model":"${server.modelId}","stream":true,
              "messages":[{"role":"user","content":"Hi"}]}"""
        .toRequestBody("application/json".toMediaType()))
    .build()
OkHttpClient().newCall(req).execute().body!!.source().use { src ->
    while (!src.exhausted()) emit(parseSseChunk(src.readUtf8Line()))
}
```

The `BackendKind.Auto` resolver picks `Llama` from the `.gguf` extension; passing `MediaPipe` or `LiteRT` (Phase 3B + 3D) switches to `.task` / `.tflite` checkpoints. The Vercel AI SDK's Kotlin port (`ai-sdk-kotlin`) and any retrofit-shaped client work unchanged because the wire is OpenAI.

### 6.8 React Native via openai-node over the TurboModule-Bound HTTP Server

The React Native package (`@dvai-bridge/react-native`, v2.2.0+) is a TurboModule that delegates to the iOS / Android native SDKs and exposes a TS facade. The integration is one `start()` call plus pointing the standard `openai` npm SDK at the returned URL:

```ts
import { DVAIBridge, BackendKind } from "@dvai-bridge/react-native";
import OpenAI from "openai";

const server = await DVAIBridge.start({
    backend: BackendKind.Auto,
    modelPath: "/path/to/Llama-3.2-1B-Instruct.Q4_K_M.gguf",
});
const openai = new OpenAI({ baseURL: server.baseUrl, apiKey: "local" });
const completion = await openai.chat.completions.create({
    model: server.modelId,
    stream: true,
    messages: [{ role: "user", content: "Hi" }],
});
for await (const chunk of completion) console.log(chunk.choices[0].delta.content);
```

The streaming SSE parser inside `openai-node` works verbatim against the TurboModule-hosted HTTP server. `useDVAIBridgeState()` is a polling-free hook backed by the platform `NativeEventEmitter`, identical in shape across iOS and Android. `BackendKind` is the union of every backend the underlying iOS + Android SDKs offer; the JS facade rejects wrong-platform requests eagerly before the native round-trip.

### 6.9 Flutter via dart:io HttpClient + Riverpod

The Flutter plugin (`dvai_bridge`, v2.3.0+, on pub.dev) is the only family member published to a public registry. The Dart facade is `DVAIBridge.instance.start(...)`, returning a `BoundServer`; any Dart HTTP client (`dart:io`, `package:http`, `package:dio`) can hit the returned URL. Riverpod consumers idiomatically wire `stateStream` into a `StreamProvider`:

```dart
final server = await DVAIBridge.instance.start(const StartOptions(
    backend: BackendKind.auto,
    modelPath: '/path/to/Llama-3.2-1B-Instruct.Q4_K_M.gguf',
));
final res = await http.post(
    Uri.parse('${server.baseUrl}/chat/completions'),
    headers: const {'Content-Type': 'application/json'},
    body: jsonEncode({
        'model': server.modelId,
        'messages': [{'role': 'user', 'content': 'Hi'}],
    }),
);

// Riverpod binding for reactive UI:
@riverpod
Stream<DVAIBridgeState> dvaiBridgeState(DvaiBridgeStateRef ref) =>
    DVAIBridge.instance.stateStream;
```

`StreamBuilder<DVAIBridgeState>` and `flutter_bloc`'s `Cubit` are equally first-class; the plugin emits identical event shapes on iOS and Android. CocoaPods consumers see the same `mlx` / `foundation` SwiftPM-only caveats that `@dvai-bridge/react-native` carries; everything else (Llama, CoreML, MediaPipe, LiteRT) works through the default pod path.

### 6.10 .NET MAUI on Catalyst via Microsoft.SemanticKernel

The .NET NuGet family (`DVAIBridge` + `DVAIBridge.iOS` / `.Android` / `.Desktop` / `.OnnxRuntime` / `.MLNet`, v2.4.0+) exposes `await DVAIBridge.Shared.StartAsync(...)` on every TFM the family supports — `net10.0`, `net10.0-ios26.2`, `net10.0-maccatalyst26.2`, `net10.0-android36.0`. The recommended .NET-side OpenAI consumer is **`Microsoft.SemanticKernel.Connectors.OpenAI`**, which configures via `Endpoint`:

```csharp
using DVAIBridge;
using Microsoft.SemanticKernel;

var server = await DVAIBridge.Shared.StartAsync(new StartOptions {
    Backend = BackendKind.Auto,
    ModelPath = await ResolveModelPathAsync(),
});

var kernel = Kernel.CreateBuilder()
    .AddOpenAIChatCompletion(
        modelId: server.ModelId,
        apiKey: "local-stub",
        endpoint: new Uri(server.BaseUrl))
    .Build();

var reply = await kernel.InvokePromptAsync("Hi");
```

On Catalyst, `BackendKind.Auto` resolves to `Llama` (Metal); pass `Foundation` for the bundled iOS-26 model, `MLX` for Apple Silicon, or `Onnx` for the cross-platform ONNX Runtime + GenAI path that also runs on Windows / Linux desktop. `ProgressEvents` is an `IAsyncEnumerable<ProgressEvent>` consumable from any `await foreach`; it interops with `Microsoft.Extensions.AI`, SignalR, and `System.IO.Pipelines` without a shim. The desktop slice ships native llama.cpp binaries via NuGet's `runtimes/<rid>/native/` mechanism, so `dotnet publish -r win-x64 --self-contained` produces a single-file desktop app with local LLM inference baked in.

### 6.11 On benchmarks: a deliberate non-goal

A reader who has skimmed every "introducing local LLM library X" post on the web will be looking for our benchmark table here. We do not publish one — and the reason is structural to what DVAI-BRIDGE *is*, not an unfinished item on a backlog.

The library is a thin shim: it accepts an OpenAI-shaped HTTP request, dispatches it to a backend (§3.6), and re-shapes the backend's response back into the OpenAI wire format. Token-generation time, time-to-first-token, throughput under load, peak VRAM, sustained battery drain, and quality-at-quantisation are **properties of the upstream backend** running underneath — WebLLM's MLC engine, Hugging Face's Transformers.js, Apple's Foundation Models / CoreML / MLX, Google's MediaPipe LLM Inference / LiteRT, ggerganov's llama.cpp, Microsoft's ONNX Runtime GenAI / ML.NET — and of the model + quantisation + device they happen to be running on. They are not properties of the few hundred lines of glue code on top of them. Publishing perf numbers attributed to "DVAI-BRIDGE" would be a category error: it would suggest we have something to measure when in fact every measurable quantity belongs upstream. A consumer who reads "DVAI-BRIDGE achieves 47 tok/s on Phi-3-mini-q4 on a Snapdragon 8 Gen 3" is really reading "MediaPipe LLM Inference achieves 47 tok/s …" — and MediaPipe already publishes their own benchmarks, more rigorously than we could.

The same observation applies to comparative studies. Comparing DVAI-BRIDGE to Ollama or `llama-server` is comparing the embedding pattern to the daemon pattern (§7), not comparing engines — both pattern endpoints can be backed by the same llama.cpp release. Comparing DVAI-BRIDGE to WebLLM-standalone is comparing the OpenAI-HTTP layer to the bare-engine layer, again on the same engine. The performance numbers are the engine's; the comparison would be about ergonomics and integration shape, which is not what benchmark tables capture.

The thing we *can* and *do* document is the **decision matrix** — which backend to pick for which platform, install base, model family, model format, and quality / battery / latency trade-off (§3.6, plus the 3.6.11 decision tree). That is the layer DVAI-BRIDGE actually contributes to: making it cheap to choose between backends, switch between them, and keep one consumer-facing interface stable while doing so. Pointing readers at the upstream engines' own benchmarks is the honest way to answer "how fast is it?".

If a reader needs a number for a procurement or capacity-planning decision, the right places to look are: the MLC team's WebLLM perf reports for browser numbers; Hugging Face's Transformers.js model cards for ONNX numbers on a given device; Apple's Foundation Models / CoreML / MLX documentation for iOS / Mac numbers; Google's MediaPipe LLM Inference perf docs and Edge AI Gallery for Android numbers; ggerganov's `llama.cpp` benchmark scripts and community boards (`llama-bench`) for GGUF numbers across every desktop platform; and Microsoft's ONNX Runtime GenAI perf docs for .NET numbers. DVAI-BRIDGE's own contribution is a consistent ~0-1 ms HTTP overhead per request — orders of magnitude below the perf signal — which is captured implicitly in any end-to-end measurement against a `dvai.baseUrl` endpoint and is not interesting in isolation.

---

## 7. Discussion: Scope, Trade-offs, Honest Positioning

It is worth stating, sharply, what DVAI-BRIDGE is and is not.

**What it is:** a _client-side inference and API-compatibility layer_ — a substrate that makes a local model answer to the OpenAI wire protocol on the device that owns the data.

**What it is not:** an in-library agent runtime. DVAI-BRIDGE does not ship an agent loop, a tool-call scheduler, a memory store, a retrieval index, or a planner. It does not define an "Agent" class. It implements a deliberately narrow slice of the OpenAI HTTP surface (`/v1/chat/completions`, `/v1/completions`, `/v1/embeddings`, `/v1/models`) and stops there.

This is a _deliberate_ architectural choice, not an omission. The design bet is that the agent ecosystem will converge on the OpenAI HTTP interface (as it has), and that _betting on the interface rather than on a specific runtime_ is the higher-leverage move. Every month, LangChain, Vercel, CrewAI, LlamaIndex, and their peers improve their agent loops. DVAI-BRIDGE inherits every one of those improvements at zero engineering cost because the interface is unchanged. If the library tried to own the agent loop itself, it would spend most of its engineering budget racing the ecosystem it depends on.

Three further trade-offs worth naming:

- **MSW is a clever transport, not a universal one.** Service Workers require an HTTPS (or localhost) origin, are blocked in some cross-origin iframes, and are not available in pure Node.js or Deno server contexts. For those contexts DVAI-BRIDGE exposes `dvai.chatCompletion()` and `dvai.createStreamingResponse()` directly, bypassing the mock layer.
- **`createPipeline` flexibility comes at the cost of a larger built-in model zoo.** The library keeps itself small and defers exotic model loaders to the caller. For most callers this is the right trade; for callers who want a shrink-wrapped experience it is friction.
- **OpenAI surface is partial.** `/v1/chat/completions`, `/v1/completions`, `/v1/embeddings`, and `/v1/models` are implemented today; `/v1/audio/*` and `/v1/images/*` are not. Embeddings now unblock fully-local RAG (with the backend caveats in §4.4), but audio and image endpoints remain prioritised future work.

The deeper point is that the library's moat is not any single backend — every backend in §3.6 is an excellent piece of upstream engineering, and none of them is ours to claim credit for. The moat is the **OpenAI-mock-as-universal-interface** pattern, plus the discipline of carrying that interface across every client-development language and every major mobile / desktop / browser platform. That is what turns nine heterogeneous runtimes into one product.

---

## 8. Forward Vision: From Bridge to Ecosystem

![Figure 5 — From bridge to ecosystem](paper-assets/fig5-ecosystem.svg)

DVAI-BRIDGE, as shipped, is a substrate. Interesting substrates invite applications — especially applications that were previously blocked by the cloud assumption.

### 8.0 Shipped Since v1

The Phase 3 line of work has retired most of what the original v1.4 paper called "future":

- **Native iOS Swift Package** (Phase 3C, v2.0.0) — `@dvai-bridge/ios`; SwiftPM + CocoaPods distribution; `.llama` / `.coreml` / `.foundation` / `.mlx` backends.
- **Native Android AAR family** (Phase 3D, v2.1.0) — `co.deepvoiceai:dvai-bridge`; `Llama` / `MediaPipe` / `LiteRT` backends; GitHub Packages Maven distribution.
- **React Native TurboModule** (Phase 3E, v2.2.0) — `@dvai-bridge/react-native`; cross-platform `BackendKind` union with eager wrong-platform validation.
- **Flutter plugin** (Phase 3F, v2.3.0) — `dvai_bridge` on pub.dev (the only family member on a public registry); `Stream<DVAIBridgeState>` for reactive consumers.
- **.NET NuGet family** (Phase 3G, v2.4.0) — six packages covering iOS / Android / Mac Catalyst / Desktop / ONNX Runtime / ML.NET; `BackendKind.Auto` / `Llama` / `Foundation` / `CoreML` / `MLX` / `MediaPipe` / `LiteRT` / `Onnx` / `MLNet`.
- **LiteRT migration** (Phase 3B) — Android backend modernised onto Google's TFLite-successor runtime; pure-Kotlin BPE tokenizer parsing.
- **Apple Foundation Models + MLX backends** (Phase 3C) — zero-download text on iOS 26+ via `LanguageModelSession`; Apple Silicon GPU/Neural Engine via `mlx-swift-lm`.
- **MediaPipe LLM Inference + LiteRT backends** (Phase 3D) — Google's bundled-task runtime plus the bare LiteRT path with a hand-rolled BPE tokenizer.

The remainder of §8 is forward-looking from this v2.4.0 baseline.

### 8.1 Roadmap for the Library Itself

- **`/v1/audio/*` endpoint** — privacy-native voice workflows (Whisper-shaped transcription, plus TTS once a stable on-device pipeline emerges).
- **`/v1/images/*` endpoint** — local vision generation (Stable-Diffusion-class through a Transformers.js or platform-native pipeline).
- **Cryptographic / signed-token license validation.** The current `LicenseValidator` remains a placeholder; a signed-token design is the planned successor for commercial deployments.

(We deliberately do **not** list "published benchmarks" here, for the reasons in §6.11 — perf belongs to the upstream backends, not to the shim layer.)

### 8.2 DVAI-Connect: E2EE Meetings with On-Device Intelligence

The first-party flagship application we are building on DVAI-BRIDGE is **DVAI-Connect**: an end-to-end-encrypted real-time meeting platform with local intelligence. In the DVAI-Connect model:

- Audio never leaves the participant's device. Speech-to-text runs inside each browser tab / Electron window via DVAI-BRIDGE's ONNX Whisper pipeline.
- Live summarisation, action-item extraction, and decision capture run against a local small model through DVAI-BRIDGE's `/v1/chat/completions` endpoint.
- Only the **encrypted transcript and the locally-derived artefacts** traverse the network, bound to a Signal-style group-key ratchet so that the meeting server itself sees nothing but ciphertext.

The contrast with current cloud-transcription offerings (Otter, Zoom AI Companion, Fireflies) is structural: those services require the meeting audio, in cleartext, inside the vendor's infrastructure. For regulated domains — legal, healthcare, financial services, M&A — that is a non-starter. DVAI-Connect is only possible _because_ the inference layer is local.

### 8.3 LifeStream: A Personal AI that Grows With the User

The second application, **LifeStream**, is at the opposite end of the sensitivity spectrum: a personal AI that learns from the user's daily life and helps them manage it. In the LifeStream model:

- The AI has longitudinal memory of the user — calendar, journaling, health signals (sleep, heart rate, activity), habits, goals, relationships.
- It coaches across dimensions that are traditionally siloed: time management, physical training, mental wellbeing, skill growth, relationship maintenance.
- The memory is _exclusively_ on-device. It is encrypted at rest, keyed to the user's hardware secure enclave, and never synchronised to a server in cleartext.

The ethical argument is the key one: a cloud-hosted version of LifeStream would be the most intimate dataset ever compiled on an individual. That kind of product is not _shippable_ under any reasonable privacy regime. It becomes deployable only when the inference (and therefore the memory it consults) is local — which is exactly what DVAI-BRIDGE provides.

### 8.4 The Broader Edge-AI Horizon

DVAI-BRIDGE, DVAI-Connect, and LifeStream are three points on a larger trajectory. The industry-wide forces pushing inference onto the device include:

- **Hardware.** Every new laptop class now ships with a dedicated NPU — Apple Neural Engine, Qualcomm Hexagon, Intel NPU, AMD XDNA, Microsoft's Copilot+ silicon. Mobile SoCs have crossed 40 TOPS. WebGPU stable is available in every major browser. The _hardware_ for local AI has quietly gone from optional to ambient.
- **Models.** The small-specialist frontier has moved decisively. Llama 3.2 1B, Gemma 2B, Phi-3-mini, and their peers reach 2023-era GPT-3.5 quality on a wide range of tasks at a fraction of the compute. Post-training quantisation from q8 down to q3 preserves most of that quality while fitting in commodity RAM.
- **Regulation.** GDPR, HIPAA, the EU AI Act, Brazil's LGPD, and comparable regimes in Asia all explicitly favour data minimisation and on-device processing. For regulated data, cloud inference is no longer the default; it is the _exception that has to be justified_.
- **Economics.** Per-token cloud pricing makes agent workflows fundamentally non-free. Every attempt to productise agent loops at scale eventually hits a pricing wall. Moving the work to the user's already-bought silicon resets the economics.

Taken together, these forces support a thesis we will commit to here: **local-first AI will become a peer tier of cloud AI, not a fallback.** Some workloads — planet-scale search, frontier-model training, workloads that require the most capable single model on earth — will stay in the cloud. But a growing class of workloads — personal assistants, regulated enterprise agents, real-time voice, privacy-sensitive knowledge work — will move to the device. DVAI-BRIDGE is our bet on the substrate that enables that migration.

---

## 9. Limitations

We list the library's real limitations candidly, so that readers and adopters can plan around them.

- **Partial OpenAI surface.** `/v1/chat/completions`, `/v1/completions`, `/v1/embeddings`, and `/v1/models` are implemented; `/v1/audio/*` and `/v1/images/*` are not.
- **Embeddings are backend-gated.** `/v1/embeddings` requires either `backend: "transformers"` with `pipelineTask: "feature-extraction"` or `backend: "native"` with `nativeEmbeddingMode: true`. WebLLM returns HTTP 400 for embedding requests because MLC runtimes do not expose embedding outputs today.
- **Native chat and native embeddings are separate contexts.** llama.cpp specialises a context at creation time — a chat-mode context cannot also produce embeddings — so an application that needs both on the native backend must construct two `DVAI` instances pointed at two GGUF files.
- **No built-in tool/function-calling runtime.** The library relies on the tool-calling loops of downstream agent SDKs (LangChain, Vercel AI SDK, CrewAI); for small local models it recommends manual JSON parsing on assistant content rather than the cloud-grade structured-tool-call protocol. This is a deliberate scope decision, not an oversight.
- **MSW constraints.** Service Worker registration requires a secure origin (HTTPS or localhost), is unavailable inside pure Web Workers, and can be blocked in sandboxed iframes. Non-browser Node.js/Deno paths must use the direct API (`dvai.chatCompletion()`, `dvai.embedding()`, `dvai.createStreamingResponse()`).
- **Licence validation is placeholder.** `LicenseValidator.ts` currently contains TODOs; a cryptographic verification design is planned for v2.
- **Test coverage spans the family but stops short of E2E real-model coverage.** Unit tests cover the JS family (core, react, vanilla, capacitor) plus native iOS, native Android, React Native, Flutter, and .NET — >300 unit tests across the family — but real-model integration tests are smoke-only (one tiny model per backend, gated behind opt-in CI). Adopters running production-shape models should run their own integration pass; the unit coverage validates the shim, not the backend.
- **First-party benchmarks are out of scope by design.** Inference perf is a property of the upstream backends DVAI-BRIDGE wraps, not of the shim itself; see §6.11 for the position and pointers to where the right numbers live.
- **No model caching layer.** Model weights are fetched from the Hugging Face CDN (Transformers.js), the MLC catalogue (WebLLM), GGUF mirrors (llama.cpp), or platform-specific stores (MediaPipe `.task`, LiteRT `.tflite`, ONNX GenAI bundles) on first run. Offline-first packaging is the caller's responsibility today, though every native SDK exposes a `downloadModel` with sha256 verification as a building block.
- **MLC LLM as a backend is parked.** A native MLC LLM mobile backend (parity with Llama / MediaPipe / LiteRT) was scoped during Phase 3 and parked pending build-chain stabilisation — see [`docs/research/2026-04-27-mlc-llm-backend-feasibility.md`](docs/research/2026-04-27-mlc-llm-backend-feasibility.md) for the parking decision and re-examination triggers.
- **No in-library agent runtime.** By design (§7), but worth restating: tool calling, retrieval, planning, and memory are delegated to external SDKs (LangChain, Vercel AI SDK, CrewAI, Microsoft.SemanticKernel, etc.).

---

## 10. Conclusion

The most interesting thing about DVAI-BRIDGE is not that it runs language models locally — several projects do that — but that it makes local models _speak OpenAI natively_, on the client, across every major client platform, through one wire contract that is identical at the edge of every SDK in the family. Mock Service Worker, a library originally written for test mocking, turns out to be the right production transport for an in-page API emulator. The pluggable driver architecture lets nine heterogeneous inference engines — WebLLM, Transformers.js, llama.cpp, Apple Foundation Models, CoreML, MLX, MediaPipe LLM Inference, LiteRT, ONNX Runtime GenAI, and ML.NET — serve the same wire contract behind a single OpenAI HTTP surface. The auto-recovery state machine papers over the practical realities of WebGPU in a browser; the same pattern carries over, less dramatically, to every other backend. And the `createPipeline` factory keeps the library small while extending its reach to arbitrary Transformers.js model families. Across every other backend the library is a thin idiomatic shim over a first-party engine, with the per-backend details documented in §3.6 so an adopter picks the right one for the platform, model family, and trade-off they care about — and never has to write the OpenAI HTTP layer themselves.

The forward vision extends the substrate. DVAI-Connect takes real-time voice intelligence off the cloud meeting server. LifeStream makes a longitudinal personal assistant ethically shippable by keeping every byte of user memory on-device. Both are applications that do not exist today, and cannot exist under cloud inference, but become straightforward under a substrate that treats the user's device as the execution environment.

We see this as the right architectural move for a defined and growing class of AI products — the class for which privacy, cost, latency, and offline capability matter more than raw model size. The cloud will continue to host frontier training and planet-scale workloads. The edge, underwritten by libraries like DVAI-BRIDGE, will host the AI that runs closest to the user's life.

---

## 11. Distributed Inference (v3.0+)

The v3 line extends the substrate beyond the single-device assumption that v1 and v2 implicitly made. The edge is no longer a single device — it is the cluster of devices a user owns. v3.0 introduces a cooperative inference layer that lets a weak device offload to a stronger device the same user is logged into, on the same Wi-Fi or across the internet, while preserving the same OpenAI HTTP contract that v1 established.

### 11.1 The problem this solves

The §6 case studies and §3.6 backend reference both implicitly assume that a model that runs on the user's *primary* device is the model they will use. That assumption holds for the canonical case — a single laptop, a single phone — but it breaks for the (common, growing) case where the user owns multiple devices of meaningfully different capability classes. A 2023 iPhone running Llama-3.2-3B at 6 tok/s while the user's Mac Studio sits idle on the same Wi-Fi at 80 tok/s is a workload mismatch the v2 architecture has no answer for. The user can't run the bigger model on the phone, and the app can't transparently route the inference to the more capable device — the result is either a degraded UX (small model only) or a cloud fallback (defeats the local-first thesis).

We considered three structural responses:

- **A) Vendor lock-in.** Ship a hosted "inference router" service that knows about all the user's devices, mediates capability negotiation, and routes requests. Cleanest UX; tightest dependency. Rejected because it makes us part of every consumer's uptime story and concentrates a man-in-the-middle position we don't want to occupy.
- **B) Per-app mesh integration.** Document a pattern where the host app's backend tracks the user's devices and supplies the library with the routing list. Maximally flexible; zero infra on our side. Useful but doesn't address the LAN case (where the host app's backend isn't even involved) or the no-host-backend case (early-stage apps without auth).
- **C) Substrate-level discovery + opt-in self-hosted relay.** LAN discovery via mDNS (zero infra, works for the common multi-device-on-one-network case); internet discovery via QR pairing through a self-hosted rendezvous server (consumer hosts; we ship the server code in the same monorepo). v3.0 ships path C.

### 11.2 What v3.0 actually does

The OpenAI HTTP wire is preserved. v2.x consumer code that doesn't opt in is unchanged. When a consumer sets `offload: { enabled: true, ... }` in their `DVAIConfig` (or the platform-equivalent on the native SDKs), the library:

1. **Probes capability** on first use of each model: a 50-token cold-run measures decode tok/s, persisted per (modelId, libraryVersion). A heuristic fallback (NPU presence + RAM + GPU class) covers the gap before the first probe runs.
2. **Discovers peers** via mDNS / DNS-SD (`_dvai-bridge._tcp.local`), per-platform implementations (`NWBrowser` on Apple, `NsdManager` on Android, `Makaretu.Dns.Multicast` on .NET desktop, `multicast-dns` in Node, no-op in browsers). Each peer's TXT record advertises its `(deviceId, dvaiVersion, deviceName, models, capability, port, secure)`.
3. **Pairs** with peers via either (a) a LAN-handshake that surfaces a one-time approval prompt to the user, or (b) a QR-scan flow through an optional self-hosted rendezvous server. Both produce a 256-bit shared key used to HMAC-sign all subsequent offload requests.
4. **Decides** per request — based on local capability, peer scores, and the `X-DVAI-Offload` header (`never | prefer | require`, default `prefer`) — whether to run locally or proxy to the best-eligible peer.
5. **Returns** a structured `no_capable_device` JSON in OpenAI-error shape (HTTP 503 + `Retry-After: 30`) when no qualified peer is reachable. Existing OpenAI clients surface this naturally — no DVAI-specific error handler required.

### 11.3 Why a self-hosted rendezvous server, not one we operate

The rendezvous server (`rendezvous/` in the monorepo, ~700 LOC of Node + Fastify + WebSocket) is **stateless beyond per-session memory**. No database. No accounts. No plaintext inference data passes through it — both pairing peers do their own AEAD encryption with a key derived from an in-WebSocket X25519 exchange. The server only relays opaque payloads.

The decision to ship it as code rather than operate it is structural: a rendezvous service we host would put us in the path of every internet-routed offload request from every dvai-bridge consumer's apps. That's a poor failure-domain story for consumers, an abuse-policing burden for us, and a perpetual cost. The right shape is to give app developers a working server they can deploy in 5 minutes (one-click buttons for Railway and DigitalOcean, with Docker / bare-VM / Fly / Render / Cloud Run / App Runner / Kubernetes documented for the rest) and let them own the inference path end-to-end.

### 11.4 Capability probes vs. published benchmarks (revisited)

§6.11 argues that first-party benchmarks are out of scope because perf belongs to upstream backends. v3.0's capability probes are not in tension with that argument. The probe measures *this device, this backend, this model, right now* — its purpose is to feed the offload decision, not to publish a comparative number. The probe result is consumer-private (cached locally, never aggregated), and it's only ever interpreted as "is local fast enough?" against a user-configurable threshold (`minLocalCapability`, default 10 tok/s). It is not a benchmark in the publication sense; it is a local capacity-planning input.

### 11.5 Privacy properties of the offload path

The HTTP contract preserves the privacy posture of v2: requests bodies are visible to the device that runs the inference, regardless of which device that is. What v3.0 adds is the question of *which device*. Two cases:

- **LAN offload.** The peer is on the same Wi-Fi, owned by the same user. The privacy story is the same as the user opening the same app on the laptop directly — they trust their own devices.
- **Rendezvous-mediated internet offload.** The relay server (which the consumer self-hosts) sees encrypted opaque payloads only. Both peers derive a shared secret via X25519 and AEAD-encrypt all relayed traffic. A compromised relay leaks pairing metadata (which devices paired with which, when) but cannot read prompts or responses.

Pairing requires explicit user approval at first contact (`onPairingRequest` callback in the SDK; the host app implements the UI). The default is *deny* — apps that don't wire the UI cannot accidentally accept pairings. Approved pairings persist for 30 days of inactivity (`expireAfterDays` configurable), then require a re-handshake.

### 11.6 What this enables that v2 couldn't

The forward vision in §8 — DVAI-Connect (E2EE meetings) and LifeStream (longitudinal personal AI) — both implicitly assumed each user device works in isolation. v3.0 unblocks application patterns those products will eventually need:

- **Phone-to-laptop offload** for prompts the phone can't serve at acceptable latency: the laptop runs the model, the phone gets the streaming response, the user sees no UX difference.
- **Family-shared compute**: a single capable device in a household can serve inference to multiple weaker devices on the same Wi-Fi without any of them paying cloud costs or shipping data outside the network.
- **Conference / event scenarios**: presenter scans a QR on the audience's app, the audience's prompts route through the presenter's beefier rig — a powerful demo pattern for showing "this app runs entirely on your devices, no cloud."

None of these are *necessary* for v2 use cases. They are the next-tier UX patterns that become possible once the substrate treats "the user's devices" as a small cluster instead of a single endpoint.

### 11.7 What v3.0 deliberately does NOT do

To preserve the spec's tight focus, v3.0 explicitly excludes:

- **Hosted relay we operate.** Per §11.3.
- **Auth tokens.** The library doesn't issue, validate, or store auth tokens. LAN pairing uses a one-time-approval HMAC; internet pairing uses ephemeral X25519 + a host-app-supplied auth header on the rendezvous URL if needed.
- **Mesh-VPN integration.** Apps that want Tailscale / ZeroTier / Headscale can use them externally. We don't ship a VPN client.
- **Streaming-protocol invention.** The offload path is HTTP (LAN) or WebSocket-tunneled HTTP shape (rendezvous). The consumer sees SSE chunks via the local OpenAI endpoint, identical to a local request.
- **Browser-as-target.** Browsers can't reliably accept inbound HTTP across origins. Browser is offload-source-only; native devices are the targets.
- **Model migration mid-stream.** If a peer drops mid-inference, that request fails. We don't checkpoint and resume. The library can optionally retry on a different peer per the `X-DVAI-Offload: prefer` policy.

These exclusions keep the v3.0 surface auditable and the failure modes legible. Each is the right shape — not because it can't be done, but because doing it would expand the substrate's responsibility into territory better owned by the host app or by external infrastructure.

### 11.8 Position in the broader picture

v1 made local models speak OpenAI on a single device. v2 made that capability cross every major client-development platform and language. v3 makes the device choice itself transparent to the agent code: the same `dvai.baseUrl` returns the result whether the inference ran on the device that received the request or on a more-capable device the user owns. The substrate's promise — "your agent code never learns where the inference ran" — extends from per-backend in v1/v2 to per-device in v3.

The pattern is intentionally orthogonal to the cloud-vs-local debate that motivates §1. v3.0 isn't an answer to "what if local isn't enough?"; it's an answer to "what if the user's local fleet has more than one device?" The cloud question stays where v1 left it: a separate tier for workloads that genuinely need it. The edge tier — now a *cluster* of devices instead of a single endpoint — gets correspondingly more capable without changing the shape of the contract that gives it those properties.

---

## References

- [WebLLM] MLC Team. _WebLLM: A High-Performance In-Browser LLM Inference Engine_. https://github.com/mlc-ai/web-llm
- [TJS] Hugging Face. _Transformers.js: State-of-the-art Machine Learning for the Web_. https://huggingface.co/docs/transformers.js
- [ORT] Microsoft. _ONNX Runtime Web_. https://onnxruntime.ai/docs/tutorials/web/
- [LlamaCpp] Gerganov, G. _llama.cpp — Port of Facebook's LLaMA model in C/C++_. https://github.com/ggerganov/llama.cpp
- [MSW] Kettanurak, A. et al. _Mock Service Worker — API Mocking of the Next Generation_. https://mswjs.io
- [LC] LangChain, Inc. _LangChain — Building applications with LLMs through composability_. https://www.langchain.com
- [Llama3] Meta AI. _The Llama 3 Herd of Models_. 2024. https://ai.meta.com/research/publications/the-llama-3-herd-of-models/
- [Gemma] Google DeepMind. _Gemma 2: Improving Open Language Models at a Practical Size_. 2024. https://blog.google/technology/developers/google-gemma-2/
- [Phi3] Microsoft Research. _Phi-3 Technical Report_. 2024. https://arxiv.org/abs/2404.14219
- [GDPR] European Parliament and Council. _Regulation (EU) 2016/679_, General Data Protection Regulation.
- [HIPAA] U.S. Department of Health and Human Services. _Health Insurance Portability and Accountability Act of 1996_.
- [EUAIAct] European Parliament and Council. _Regulation (EU) 2024/1689 on Artificial Intelligence_.
- [Capacitor] Ionic. _Capacitor — Cross-platform native runtime for web apps_. https://capacitorjs.com
- [WebGPU] W3C. _WebGPU — Working Draft_. https://www.w3.org/TR/webgpu/
- [AppleFM] Apple. _Foundation Models framework — On-device large language model inference_. https://developer.apple.com/documentation/foundationmodels
- [MLX] Apple Machine Learning Research. _MLX — An array framework for Apple silicon_. https://github.com/ml-explore/mlx
- [MediaPipe] Google. _MediaPipe LLM Inference Guide_. https://ai.google.dev/edge/mediapipe/solutions/genai/llm_inference
- [LiteRT] Google. _LiteRT — TensorFlow Lite's successor for on-device ML_. https://ai.google.dev/edge/litert
- [MLNet] Microsoft. _ML.NET — Open-source machine learning framework for .NET_. https://dotnet.microsoft.com/en-us/apps/ai/ml-dotnet
- [ORTGenAI] Microsoft. _ONNX Runtime GenAI — Generative AI extensions for ONNX Runtime_. https://github.com/microsoft/onnxruntime-genai
- [SemanticKernel] Microsoft. _Semantic Kernel — Integrate cutting-edge LLM technology into your apps_. https://github.com/microsoft/semantic-kernel
- [Pigeon] Flutter. _Pigeon — Code generator for type-safe Flutter platform-channel APIs_. https://pub.dev/packages/pigeon
- [TurboModules] Meta. _React Native TurboModules — JSI-based native module system_. https://reactnative.dev/docs/the-new-architecture/landing-page

---

_© 2026 Deep Voice AI Limited. Licensed to the public under the terms accompanying the DVAI-BRIDGE distribution._
