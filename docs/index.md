---
layout: home

hero:
  name: "DVAI-Bridge"
  text: "One local OpenAI server, embedded everywhere."
  tagline: "Web, iOS, Android, React Native, Flutter, and .NET — six SDKs, nine backends, one HTTP surface. Zero cloud cost. Zero install for your users."
  image:
    src: /banner.png
    alt: DVAI-Bridge Banner
  actions:
    - theme: brand
      text: Get Started
      link: /guide/getting-started
    - theme: alt
      text: View on GitHub
      link: https://github.com/Westenets/dvai-bridge

features:
  - title: 📱 Six SDKs, one API
    details: Web, iOS (Swift), Android (Kotlin), React Native, Flutter, and .NET (MAUI / Avalonia / WinUI / Catalyst / desktop). Same OpenAI HTTP contract on every platform; switch the import, keep the agent code.
  - title: 🚀 Nine backends
    details: WebLLM, Transformers.js, llama.cpp, Apple Foundation Models, CoreML, MLX, MediaPipe LLM, LiteRT, and (.NET only) ONNX Runtime + ML.NET. Picked automatically per platform; opt into specifics when you need to.
  - title: 🛡️ Auto-Recovery
    details: Blank-chunk detection, generation timeout, and a bounded recovery loop that unloads + reloads the engine on fatal errors. Users see a brief reload instead of a broken UI.
  - title: ⚛️ First-class React + native
    details: React Hooks for the JS family; idiomatic Swift actors, Kotlin coroutines, Pigeon-typed Dart APIs, and async C# Tasks for the native SDKs. No JS-side state machine to learn.
  - title: 🍦 Any framework
    details: Works in Vanilla JS, Vue, Svelte, Angular, SwiftUI, UIKit, Compose, MAUI, WinUI, Avalonia. The OpenAI HTTP surface is the only contract you depend on.
  - title: 🤖 Agent SDK Ready
    details: LangChain, Vercel AI SDK, OpenAI's official SDKs (Python, JS, Swift, .NET), Microsoft.SemanticKernel, CrewAI, LlamaIndex — all work unchanged. Point them at dvai.baseUrl.
  - title: 🎨 Multi-modal
    details: Declarative loader for text + image + audio models (Gemma 4, LLaVA, Idefics, Whisper) on Transformers.js. Runs in the Web Worker by default; main thread stays unblocked during inference.
  - title: 📦 Hybrid backend selection
    details: backend "auto" picks the best path per runtime — WebLLM in browsers, llama.cpp on mobile + desktop, Foundation Models on iOS 18.4+, etc. Override per request when you need to.
  - title: 🔒 100% local + private
    details: Zero API costs, zero server maintenance, no data leaves the device. Works offline. Suitable for healthcare, legal, finance, M&A, and any other regulated workload where cloud inference is a non-starter.
---
