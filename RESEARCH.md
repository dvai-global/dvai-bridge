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

### 6.11 What Remains Unmeasured

Honest disclosure: the current codebase and documentation carry **no published benchmarks**. Specifically absent are:

- **Latency.** Time-to-first-token and tokens-per-second for each driver × model × device class combination.
- **Throughput under load.** Behaviour under concurrent agent calls in the same tab.
- **Memory footprint.** Peak VRAM and RSS across model sizes and quantisations.
- **Power and thermals.** Mobile-device sustained inference battery cost and thermal throttling curves.
- **Quality-at-quantisation.** Task-level quality drop from q8 → q6 → q4 → q3 for each driver's supported quantisation set.
- **Comparative studies** against Ollama (server-local), WebLLM-standalone, and direct OpenAI calls.

We regard closing this gap as the most important near-term research task. A proposed methodology: fix a small test suite (e.g., MT-Bench subset, a tool-calling suite, and three retrieval-grounded QA sets) and run it end-to-end through each driver on three reference devices (a WebGPU-capable laptop, an Electron desktop with dGPU, and a current-generation iPhone/Android), reporting latency percentiles, tokens per second, and task accuracy.

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

The deeper point is that the library's moat is not any single backend — Transformers.js and WebLLM are both excellent, but neither is proprietary. The moat is the **OpenAI-mock-as-universal-interface** pattern. That is what turns three heterogeneous runtimes into one product.

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
- **Published benchmarks** per §6.11 — the open methodology gap from the v1.4 paper, still open at v2.4.0.

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
- **Test coverage spans the family but stops short of E2E real-model coverage.** Unit tests cover the JS family (core, react, vanilla, capacitor) plus native iOS, native Android, React Native, Flutter, and .NET — >300 unit tests across the family — but published benchmarks against real models on real devices remain absent (see next item).
- **No published benchmarks.** The methodology proposed in §6.11 — fixed test suites, three reference devices, latency / throughput / memory / power / quality-at-quantisation reporting — has not been executed.
- **No model caching layer.** Model weights are fetched from the Hugging Face CDN (Transformers.js), the MLC catalogue (WebLLM), GGUF mirrors (llama.cpp), or platform-specific stores (MediaPipe `.task`, LiteRT `.tflite`, ONNX GenAI bundles) on first run. Offline-first packaging is the caller's responsibility today, though every native SDK exposes a `downloadModel` with sha256 verification as a building block.
- **MLC LLM as a backend is parked.** A native MLC LLM mobile backend (parity with Llama / MediaPipe / LiteRT) was scoped during Phase 3 and parked pending build-chain stabilisation — see [`docs/research/2026-04-27-mlc-llm-backend-feasibility.md`](docs/research/2026-04-27-mlc-llm-backend-feasibility.md) for the parking decision and re-examination triggers.
- **No in-library agent runtime.** By design (§7), but worth restating: tool calling, retrieval, planning, and memory are delegated to external SDKs (LangChain, Vercel AI SDK, CrewAI, Microsoft.SemanticKernel, etc.).

---

## 10. Conclusion

The most interesting thing about DVAI-BRIDGE is not that it runs language models locally — several projects do that — but that it makes local models _speak OpenAI natively_, on the client, across Web, Desktop, and Mobile, through a single TypeScript API. Mock Service Worker, a library originally written for test mocking, turns out to be the right production transport for an in-page API emulator. The pluggable driver architecture lets three heterogeneous inference engines (WebLLM, Transformers.js, llama.cpp) serve the same wire contract. The auto-recovery state machine papers over the practical realities of WebGPU in a browser. And the `createPipeline` factory keeps the library small while extending its reach to arbitrary Transformers.js model families.

The forward vision extends the substrate. DVAI-Connect takes real-time voice intelligence off the cloud meeting server. LifeStream makes a longitudinal personal assistant ethically shippable by keeping every byte of user memory on-device. Both are applications that do not exist today, and cannot exist under cloud inference, but become straightforward under a substrate that treats the user's device as the execution environment.

We see this as the right architectural move for a defined and growing class of AI products — the class for which privacy, cost, latency, and offline capability matter more than raw model size. The cloud will continue to host frontier training and planet-scale workloads. The edge, underwritten by libraries like DVAI-BRIDGE, will host the AI that runs closest to the user's life.

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
