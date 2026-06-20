# Introduction

## What is DVAI-Bridge?

DVAI-Bridge is a local AI SDK for building cross-platform apps that ship
AI inside the app itself — not behind a cloud API, not behind a server the
user has to install.

It runs an OpenAI-compatible HTTP server inside your app process. You
point any OpenAI client at it, and the same agent code you wrote for the
cloud keeps working. Locally. Privately. For free.

```ts
import { DVAI } from "@dvai-bridge/core";
import OpenAI from "openai";

const dvai = new DVAI({ backend: "auto" });
await dvai.initialize();

const openai = new OpenAI({ baseURL: dvai.baseUrl, apiKey: "ignored" });
const r = await openai.chat.completions.create({
  model: "any",
  messages: [{ role: "user", content: "Hello!" }],
});
```

That's the whole contract.

## Why local AI?

Cloud AI works — until you try to ship a real product. Three costs always
catch up.

- **Per-token fees.** Every user query costs money. High-volume apps burn through budgets fast.
- **Privacy exposure.** Sensitive data leaves the device. Healthcare, legal, and finance apps can't accept that.
- **Infrastructure burden.** Keys, rate limits, rotation, secret storage — all for what should be "just run the model."

Local inference fixes those — until shipping day. Ollama needs the user
to install Ollama. llama.cpp wants a sidecar binary. WebLLM is browser-only.
Every team that tries to ship a production AI app hits this wall.

DVAI-Bridge ships *inside your app*, on every platform, with the same
OpenAI HTTP wire. The wall goes away.

## What you get

- **Zero per-token cost.** Run forever; no billing limit.
- **Full privacy.** Inference runs on the user's hardware. The data never leaves.
- **Zero install for your user.** Your app already contains the AI.
- **Works offline.** Aeroplane mode. Hospital networks. Enterprise air-gaps. Still works.
- **Any agent SDK, unchanged.** LangChain, OpenAI SDK, Vercel AI SDK, CrewAI — point `baseURL` at `dvai.baseUrl`.

## What it covers

One SDK shape, six runtimes, five registries.

- **Browser** — React, Vue, Svelte, vanilla JS.
- **Node and Bun** — server-side or CLI.
- **Electron** — the main process gets full-native GPU acceleration.
- **Capacitor hybrid** — one bundle for iOS and Android.
- **iOS native** — Swift via SwiftPM / CocoaPods (`DVAIBridge`).
- **Android native** — Kotlin / Java via Maven Central (`co.deepvoiceai:dvai-bridge`).
- **React Native** — TurboModule on RN ≥ 0.77 (`@dvai-bridge/react-native`).
- **Flutter** — Dart on pub.dev (`dvai_bridge`).
- **.NET 10 LTS** — C# on NuGet — covers .NET MAUI on iOS / Android, Mac Catalyst, Avalonia / WinUI desktop, and Windows / macOS / Linux console apps.

Same OpenAI HTTP surface. Same method names. Different package, same behaviour.

## How it works

Three layers, the same on every platform.

- **The engine** — picks itself by default. Apple Foundation Models on supported iPhones. MLX on Apple Silicon Macs. llama.cpp where it fits. MediaPipe LLM and LiteRT on Android. WebLLM and Transformers.js in browsers. ONNX Runtime on .NET.
- **The HTTP server** — `127.0.0.1:38883`, with port fallback. Endpoints are exactly OpenAI's: `/v1/chat/completions`, `/v1/embeddings`, `/v1/models`. Streaming is SSE, exactly the way OpenAI streams.
- **The SDK** — one idiomatic surface per language. Swift actors. Kotlin coroutines. Pigeon-typed Dart APIs. Async C# Tasks. React hooks for the JS family.

In the browser, the "server" is a Service Worker that intercepts fetch
calls — no actual TCP. Same OpenAI URL pattern, same response shape.

## Distributed inference

Since v3.0, a phone can offload heavy inference to a stronger device on
the same Wi-Fi. The strong device is **DVAI Hub** — a small installable
utility — or any other app embedding DVAI-Bridge.

Pairing is encrypted end-to-end. Requests are HMAC-signed. The phone
keeps its OpenAI HTTP surface — only the engine moves.

For cross-network paths, run a [self-hosted rendezvous server](/guide/self-hosting-rendezvous).

## Auto-recovery

If a model gets stuck — blank output, generation timeout, GPU crash —
DVAI-Bridge unloads the engine, reloads it, and retries the request up
to a bounded count. Users see a brief progress update. Not a broken UI.

## Any model

DVAI-Bridge doesn't hardcode a list of supported models. Three paths, in
order of preference.

- **`pipeline()` default** — set `transformersModelId` + `pipelineTask`. Thousands of models on Hugging Face work with no extra config.
- **[Declarative multimodal loader](/guide/backends#declarative-multimodal-loader)** — for models with named classes (multimodal LLMs, vision-language, speech-to-text with chat). Runs in a Web Worker; main thread stays free.
- **[Custom Pipeline Factory](/guide/backends#custom-pipeline-factory-createpipeline)** — escape hatch for exotic processors. You supply a factory; DVAI handles transport, endpoints, streaming, formatting.

Most cutting-edge multimodal models need only the first two.

## What's next

- [Get started](/guide/getting-started) — five-minute install + first chat.
- [Pick your platform](/guide/license/) — per-SDK walkthrough.
- [Backends](/guide/backends) — choose or override engines.
- [How it compares](/guide/comparison) — DVAI-Bridge vs Ollama, LiteLLM, LangChain, and QVAC.
