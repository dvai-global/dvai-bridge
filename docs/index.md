---
layout: home

hero:
  name: "DVAI-Bridge"
  text: "Local AI in any app."
  tagline: "One SDK on every platform. The model runs on the user's device. Any agent framework that speaks OpenAI works without changes."
  image:
    src: /banner.png
    alt: DVAI-Bridge Banner
  actions:
    - theme: brand
      text: Get started
      link: /guide/getting-started
    - theme: alt
      text: View on GitHub
      link: https://github.com/dvai-global/dvai-bridge

features:
  - title: One import, every platform
    details: Swift on iOS, Kotlin on Android, Dart on Flutter, TypeScript on the web and React Native, C# on .NET — same OpenAI HTTP wire on each.
  - title: The model runs on the device
    details: No cloud calls. No per-token bill. No data leaves the user's hardware. Works offline.
  - title: The engine picks itself
    details: Apple Foundation Models, MLX, llama.cpp, CoreML, MediaPipe, LiteRT — selected per device. Override per request when you need to.
  - title: Your agents already work
    details: LangChain, the OpenAI SDKs, Vercel AI SDK, CrewAI, LlamaIndex — point them at the local URL and run.
  - title: Multi-modal
    details: Text, images, audio. Gemma 4, LLaVA, Whisper. Runs in a worker; the main thread stays free.
  - title: Built for production
    details: Auto-recovery on bad output, generation timeout, bounded reload — users see a brief reload, not a broken screen.
  - title: Pair a phone with a desktop
    details: DVAI Hub offloads heavy inference from a phone to a paired laptop on the same Wi-Fi. End-to-end encrypted.
  - title: Six SDKs, five registries
    details: npm, Maven Central, CocoaPods, pub.dev, NuGet. Install the one for your stack — the rest are the same shape.
  - title: Embedded in your app
    details: Not a gateway. Not an end-user-installed server. Ships inside the app you build.
---

## Why DVAI-Bridge?

DVAI-Bridge embeds an OpenAI-compatible AI server inside your app — so the
same agent code you wrote for cloud OpenAI keeps working, just locally.

The model runs on the user's device. The HTTP server runs in your app's own
process. No cloud account. No per-token bill. No install for your user.

It is **not** a gateway like LiteLLM. It is **not** a server your user has
to install like Ollama. It is **not** a framework SDK like LangChain. It
is the thin layer between your code and the model — the same shape on
iOS, Android, Flutter, React Native, .NET, and the web.

## Capabilities

- **Text generation** — LLM chat and completions on every platform.
- **Embeddings** — Vector embeddings for RAG and semantic search.
- **Multi-modal** — Text + image + audio via Gemma 4, LLaVA, Whisper, and more.
- **Streaming** — Server-Sent Events for token-by-token output, the same way OpenAI streams.
- **Offload to a paired device** — DVAI Hub lets a phone hand heavy inference to a laptop on the same Wi-Fi.
- **Auto-recovery** — Detects bad output, restarts the engine, retries the request — silently.

## System overview

Three layers, the same on every platform.

- **The engine** — llama.cpp, Apple Foundation Models, MLX, CoreML, MediaPipe LLM, LiteRT, WebLLM, or Transformers.js. Picked at runtime.
- **The HTTP server** — `127.0.0.1:38883`, `/v1/chat/completions`, `/v1/embeddings`, `/v1/models`. The OpenAI wire, exactly.
- **The SDK** — one idiomatic surface per language. Same method names, same lifecycle, same behaviour.

## Next steps

- [Get started](/guide/getting-started) — install and run your first local chat in five minutes.
- [Pick your platform](/guide/license/) — per-SDK setup, including the license JWT for production.
- [Why this design](/guide/introduction) — the longer-form story behind the architecture.
- [How it compares](/guide/comparison) — DVAI-Bridge vs Ollama, LiteLLM, LangChain, and QVAC.
