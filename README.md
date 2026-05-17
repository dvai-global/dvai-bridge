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
| Browser (React, Vue, Svelte, vanilla JS) | `@dvai-bridge/core` + `react` / `vanilla` | WebLLM (WebGPU), Transformers.js (WebGPU / WASM SIMD) |
| Node / Bun / Electron | `@dvai-bridge/core` | Transformers.js, native llama.cpp |
| Capacitor hybrid mobile | `@dvai-bridge/capacitor` + backend slice | Native llama.cpp (Metal iOS, Vulkan / CPU Android) |
| iOS native (Swift) | `DVAIBridge` (SPM / CocoaPods) | llama.cpp (Metal), CoreML / ANE, Apple Foundation Models, MLX |
| Android native (Kotlin / Java) | `co.deepvoiceai:dvai-bridge` (AAR) | llama.cpp, MediaPipe LLM, LiteRT, NNAPI / QNN |
| React Native (≥0.77, TurboModule) | `@dvai-bridge/react-native` | All iOS + Android backends (delegates) |
| Flutter (≥3.39) | `dvai_bridge` (pub.dev) | All iOS + Android backends (Pigeon channels) |
| .NET 10 LTS (MAUI / Avalonia / WinUI / Catalyst / desktop) | `co.deepvoiceai.dvai-bridge*` (NuGet) | iOS / Android delegate to native; desktop = llama.cpp + ONNX Runtime GenAI + ML.NET |

Full quickstart per platform: [bridge.deepvoiceai.co/docs](https://bridge.deepvoiceai.co/docs)

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
