![DVAI-Bridge](/assets/banner.png)

# DVAI-Bridge

<!-- [![Smoke — real models](https://github.com/dvai-global/dvai-bridge/actions/workflows/smoke-real-models.yml/badge.svg?branch=main)](https://github.com/dvai-global/dvai-bridge/actions/workflows/smoke-real-models.yml) -->

[![License](https://img.shields.io/badge/License-Commercial-blue.svg)](LICENSE) ![Node.js](https://img.shields.io/badge/Node.js-22+-green?logo=node.js) ![TypeScript](https://img.shields.io/badge/TypeScript-5.6+-blue?logo=typescript) ![Swift](https://img.shields.io/badge/Swift-5.9+-F05138?logo=swift) ![Kotlin](https://img.shields.io/badge/Kotlin-2.0+-7F52FF?logo=kotlin) ![Flutter](https://img.shields.io/badge/Flutter-3.39+-02569B?logo=flutter) ![.NET](https://img.shields.io/badge/.NET-10.0_LTS-512BD4?logo=dotnet)

> **The local OpenAI server you embed inside your app.**
> One library. One HTTP wire. Every platform. Zero install for your users.

**Docs:** [bridge.deepvoiceai.co](https://bridge.deepvoiceai.co)  

**Patent pending —** UK patent application **GB2611312.6** filed 14 May 2026.

```ts
import { DVAI } from "@dvai-bridge/core";
import OpenAI from "openai";

const dvai = new DVAI({ backend: "transformers" });
await dvai.initialize();

const openai = new OpenAI({ baseURL: dvai.baseUrl, apiKey: "ignored" });
await openai.chat.completions.create({
  model: dvai.transformersModelId,
  messages: [{ role: "user", content: "Hello!" }],
});
```

That's it. A real OpenAI-compatible server is now running inside your app's
own process. Point any OpenAI client — LangChain, the OpenAI SDK, the Vercel
AI SDK, anything — at `dvai.baseUrl` and your agent code keeps working.

Built by **[Deep Voice AI](https://deepvoiceai.co)**.

---

## Why it exists

Local AI works beautifully on a laptop with **Ollama + LangChain**. Then you
try to ship the app and your users don't have Ollama. Mobile can't run it.
Corporate IT won't add another daemon. So you reinvent the same plumbing —
spawn an inference engine, bind a port, translate to OpenAI HTTP, handle
CORS, manage lifecycle, wrap the accelerator of the day per platform — and
do it all over again for every target OS.

DVAI-Bridge is that plumbing, packaged as a library, for every client
platform.

---

## What you get

- **One OpenAI HTTP surface.** Bound on `127.0.0.1` (or `0.0.0.0` for
  device-to-device). Streaming, embeddings, models, recovery — all built in.
- **Six SDKs.** `@dvai-bridge/core` + `react` + `vanilla` + `capacitor`,
  `DVAIBridge` (Swift / iOS), `co.deepvoiceai:dvai-bridge` (Kotlin / Android),
  `@dvai-bridge/react-native`, `dvai_bridge` (Flutter), `co.deepvoiceai.dvai-bridge` (.NET).
- **Nine backends.** WebLLM, Transformers.js, llama.cpp, Apple Foundation
  Models, MLX, CoreML / ANE, MediaPipe LLM, LiteRT, ONNX Runtime GenAI —
  selected per-platform, invisible to your agent code.
- **Native acceleration** wherever it runs: WebGPU in browsers, CUDA / Metal
  / Vulkan / DirectML on desktop, ANE / Metal / MLX on iOS, NNAPI / QNN
  Hexagon / GPU delegate on Android.
- **Multimodal.** Text, image, audio, video — declarative loader for
  cutting-edge models (Gemma 4, LLaVA, Idefics) without waiting for library
  updates.
- **Distributed inference (v3.0+).** Phone too slow? Offload to your laptop
  on the same Wi-Fi via mDNS pairing — same OpenAI wire, transparent to
  your code. Internet path via a self-hostable rendezvous server.
- **DVAI Hub (v3.1+).** A first-party desktop utility that turns any device
  into a strong-peer for the rest of your fleet. Brand-neutral install via
  Homebrew / winget / GitHub Releases, OR fork it for your own branded
  companion. Routes through Ollama / LM Studio / vLLM / llama-server /
  llamafile if you've already got those running.
- **Zero user install.** It's a library, not a daemon. `npm install`,
  `cocoapods`, gradle — your CI already has the muscle for it.

---

## Supported platforms

| Stack | Package | Backends |
| --- | --- | --- |
| Browser (React, Vue, Svelte, vanilla JS) | [`@dvai-bridge/core`](https://www.npmjs.com/package/@dvai-bridge/core) + [`react`](https://www.npmjs.com/package/@dvai-bridge/react) / [`vanilla`](https://www.npmjs.com/package/@dvai-bridge/vanilla) | WebLLM (WebGPU), Transformers.js (WebGPU / WASM SIMD) |
| Node / Bun / Electron | [`@dvai-bridge/core`](https://www.npmjs.com/package/@dvai-bridge/core) | Transformers.js, native llama.cpp |
| Capacitor hybrid mobile | [`@dvai-bridge/capacitor`](https://www.npmjs.com/package/@dvai-bridge/capacitor) + backend slice ([llama](https://www.npmjs.com/package/@dvai-bridge/capacitor-llama) / [mediapipe](https://www.npmjs.com/package/@dvai-bridge/capacitor-mediapipe) / [foundation](https://www.npmjs.com/package/@dvai-bridge/capacitor-foundation) / [mlx](https://www.npmjs.com/package/@dvai-bridge/capacitor-mlx)) | Native llama.cpp (Metal iOS, Vulkan / CPU Android) |
| iOS native (Swift) | `DVAIBridge` ([SPM](https://github.com/dvai-global/dvai-bridge) / [CocoaPods](https://cocoapods.org/pods/DVAIBridge)) | llama.cpp (Metal), CoreML / ANE, Apple Foundation Models, MLX |
| Android native (Kotlin / Java) | [`co.deepvoiceai:dvai-bridge`](https://central.sonatype.com/artifact/co.deepvoiceai/dvai-bridge) (Maven Central AAR) | llama.cpp, MediaPipe LLM, LiteRT, NNAPI / QNN |
| React Native (≥0.77, TurboModule) | [`@dvai-bridge/react-native`](https://www.npmjs.com/package/@dvai-bridge/react-native) | All iOS + Android backends (delegates) |
| Flutter (≥3.39) | [`dvai_bridge`](https://pub.dev/packages/dvai_bridge) | All iOS + Android backends (Pigeon channels) |
| .NET 10 LTS (MAUI / Avalonia / WinUI / desktop / Catalyst) | [`DVAIBridge`](https://www.nuget.org/packages/DVAIBridge) facade + [`.Desktop`](https://www.nuget.org/packages/DVAIBridge.Desktop) / [`.iOS`](https://www.nuget.org/packages/DVAIBridge.iOS) / [`.Android`](https://www.nuget.org/packages/DVAIBridge.Android) / [`.OnnxRuntime`](https://www.nuget.org/packages/DVAIBridge.OnnxRuntime) / [`.MLNet`](https://www.nuget.org/packages/DVAIBridge.MLNet) (NuGet) | iOS / Android delegate to native; desktop = llama.cpp + ONNX Runtime GenAI + ML.NET. Mac Catalyst slice shipped in v4.0.1. |

Full quickstart per platform: [bridge.deepvoiceai.co/docs](https://bridge.deepvoiceai.co/docs)

---

## Isn't this just LiteLLM / LangChain / Ollama?

Short answer: no — those tools assume something DVAI-Bridge ships. Long answer:

The on-device-LLM space already has plenty of moving parts. Developers I've
talked to often ask "isn't this reinventing the wheel?" — usually pointing
at one of these:

- **[LiteLLM](https://github.com/BerriAI/litellm) / [OpenRouter](https://openrouter.ai/) / [LangChain](https://www.langchain.com/)** — gateway and router libraries.
  Excellent at fanning a request to many backends, but **they assume a
  server is already running** (cloud, or a local one the user installed).
  They route TO an inference engine; they aren't one.
- **[Ollama](https://ollama.com/) / [LM Studio](https://lmstudio.ai/) / [vLLM](https://docs.vllm.ai/) / [llama-server](https://github.com/ggml-org/llama.cpp/tree/master/tools/server) / [llamafile](https://github.com/Mozilla-Ocho/llamafile) / [LocalAI](https://localai.io/) / [Jan.ai](https://jan.ai/)** —
  local OpenAI-compatible servers. Great on a developer laptop. But
  **the end user has to install them**, configure a port, keep them
  running, and update them out-of-band from your app. Mobile users
  can't install any of these. Corporate IT won't approve "yet another
  daemon".
- **[llama.rn](https://github.com/mybigday/llama.rn) / [Capacitor LocalLLM](https://github.com/Mediapipe-One/CapacitorPlugin-LocalLLM) / [ExecuTorch](https://pytorch.org/executorch/) / [MLX-Swift](https://github.com/ml-explore/mlx-swift) / [MediaPipe LLM Inference](https://ai.google.dev/edge/mediapipe/solutions/genai/llm_inference)** —
  embedded runtimes that DO ship inside the app, but **expose JS-bridge
  or native-only APIs**. Agentic frameworks (LangChain, autogen, crewai,
  the OpenAI SDK itself) can't talk to them without per-runtime adapters.
- **[WebLLM](https://github.com/mlc-ai/web-llm) / [Wllama](https://github.com/ngxson/wllama) / [Transformers.js](https://huggingface.co/docs/transformers.js)** —
  browser-only WebGPU / WASM runtimes. Useful, but not what you ship in
  a mobile app or a MAUI desktop binary.
- **[LM Studio LM Link](https://lmstudio.ai/link) / Tailscale-for-LLMs / [Magic Wormhole](https://magic-wormhole.readthedocs.io/)-style relays** —
  cross-network LLM routing. All require **installs on both ends** plus
  a coordinator account, with the operator (Tailscale, LM Studio's
  backend) able to revoke or observe the link.

DVAI-Bridge isn't a competitor to any of those — it's a different shape
of thing. The six properties below define what it actually is, and they
hold simultaneously. No existing tool combines all six.

### Six things that hold simultaneously

1. **Your app IS the server.** The inference runtime is in your app
   bundle, not a daemon the end user installs. `npm install`, `pod
   install`, `gradle`, `NuGet`. Models download on first use, resumable,
   sha256-verified. No "please install Ollama first" step in your
   onboarding.
2. **Real OpenAI HTTP, inside the app process.** A loopback HTTP server
   on `127.0.0.1` serves `/v1/chat/completions`, `/v1/embeddings`,
   `/v1/models`, with SSE streaming and the standard error envelope.
   Any OpenAI client speaks to it. Your agent code from a cloud
   prototype runs locally with `baseURL = dvai.baseUrl` and **nothing
   else changes**.
3. **One library, every client platform.** Same OpenAI surface from
   npm (browser, Node, React, React Native, Capacitor), CocoaPods
   (iOS Swift), Maven Central (Android Kotlin), pub.dev (Flutter), and
   NuGet (.NET MAUI / Avalonia / WinUI / Catalyst). A Flutter
   developer, a Swift developer, and a React Native developer hit
   identical endpoints with identical request/response shapes.
4. **Backend-agnostic per device.** Your code says
   `backend: 'auto'` — the SDK picks llama.cpp / Apple Foundation
   Models / MLX / CoreML+ANE / MediaPipe LLM / LiteRT / WebLLM /
   Transformers.js / ONNX Runtime GenAI based on what the device
   actually supports. The agentic framework on top **doesn't know or
   care** which engine is executing.
5. **Local-first with optional peer expansion.** LAN-mDNS capability
   discovery + cross-network self-hostable WebSocket rendezvous.
   Phone too slow? Transparently push to your Mac on the same Wi-Fi
   — same OpenAI wire, same `baseURL`. Need it across networks?
   Self-host the rendezvous (no default operator, no third-party
   broker). Both modes opt-in; both expose the same wire to the
   consuming code.
6. **Zero user setup.** End users don't install Ollama, configure
   Tailscale, or run llama-server. They install **your app**.
   Everything else is invisible.

The combination is the gap. Each component exists in isolation
somewhere in the prior art (and is dutifully credited in the
[architecture docs](https://bridge.deepvoiceai.co/architecture)) —
but no single existing tool ships all six in one package.

---

## Examples

```ts
// React
import { DVAIProvider, useDVAI } from "@dvai-bridge/react";
<DVAIProvider config={{ backend: "transformers" }}>
  <Chat />
</DVAIProvider>;
function Chat() {
  const { isReady, baseUrl } = useDVAI();
  return isReady ? <div>Local AI live at {baseUrl}</div> : <Loading />;
}
```

```swift
// iOS
let server = try await DVAIBridge.shared.start()
// server.baseUrl = "http://127.0.0.1:38883/v1"
```

```kotlin
// Android
val server = DVAIBridge.start(context)
// server.baseUrl = "http://127.0.0.1:38883/v1"
```

```dart
// Flutter
final state = await DVAIBridge.instance.start(
  backend: BackendKind.auto,
  modelPath: '/path/to/model.gguf',
);
// state.baseUrl = "http://127.0.0.1:38883/v1"
```

```csharp
// .NET
var server = await DVAIBridge.Shared.StartAsync(new StartOptions {
    Backend = BackendKind.Auto,
    ModelPath = "/path/to/model.gguf",
});
// server.BaseUrl = "http://127.0.0.1:38883/v1"
```

Multimodal, streaming, embeddings, distributed offload, the Hub —
everything's at the [docs site](https://bridge.deepvoiceai.co).

---

## What's new in v4.0

- **Full CocoaPods Support** — Streamlined integration for iOS and macOS projects via CocoaPods with robust handling of vendored xcframeworks and strict release sanitization.
- **Capacitor v8 Ready** — Upgraded compatibility with Capacitor v8 across native tooling and dependency resolution.
- **Enhanced iOS HTTP Engine** — Modernized Swift HTTP server, refined JWT payload handling, and better dependency management for iOS targets.
- **Publishing & Dependency Upgrades** — Switched to npm registry for package publishing, added extensive monorepo verification tools, and unified release packaging.
- **DVAI Hub & Distributed Inference (v3+)** — Tauri desktop utility (`brew install deepvoiceai/dvai-hub/dvai-hub` or `winget install DeepVoiceAI.DVAIHub`) allows mobile apps on the same Wi-Fi to offload heavy inference. [Guide →](https://bridge.deepvoiceai.co/guide/dvai-hub)
  [Migration v3.0 → v3.1 →](https://bridge.deepvoiceai.co/migration/v3.0-to-v3.1)

---

## Robustness

Streaming-correct (SSE passthrough + blank-chunk detection), generation
timeout, automatic engine-state recovery on fatal errors, port fallback,
worker offloading, Private Network Access ready, CORS configured. The
boring substrate so your agent code never has to think about it.

---

## Licensing

Dual: **free for development & personal use** on `localhost` (verified at
runtime). **Commercial use** requires a license key — `info@deepvoiceai.co`.

---

## Contributing

PRs welcome.

```bash
pnpm install
pnpm build
bash scripts/build-all.sh   # full matrix (auto-skips per-host)
```

[`CONTRIBUTING.md`](./CONTRIBUTING.md) for the PR flow. Per-platform
contributor docs (iOS / Android / RN / Flutter / .NET) under
[`docs/development/`](./docs/development/).

---

© Deep Voice AI Limited. All rights reserved.
