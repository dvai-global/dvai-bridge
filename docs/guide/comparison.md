# How it compares

DVAI-Bridge sits in one specific spot: **a library, embedded inside your
app, speaking OpenAI HTTP, on every major client platform.** No other
project covers all three at once. This page explains where each
alternative fits — and when the right answer isn't DVAI-Bridge.

## The short version

- Building and shipping an app — iOS, Android, Flutter, React Native, .NET, Electron, Capacitor, or web — and you want local AI inside it? **DVAI-Bridge.**
- Running models on your own dev machine? **Ollama** or **LM Studio.**
- Whole stack is Python? **`llama-cpp-python`**.
- Browser-only demo? **WebLLM** or **Transformers.js**.
- Routing across cloud providers? **LiteLLM** or **OpenRouter**.

## The three axes

Local-AI projects sit on three axes.

- **Library or product?** A library is what a developer imports. A product is what a user installs.
- **How many platforms?** Some run only on desktop, some only in the browser, some only on one OS.
- **How many languages?** Most libraries are single-language. DVAI-Bridge is the first to ship first-party bindings for every major client language.

The slot DVAI-Bridge fills: **library × cross-platform × cross-language.**

|                  | Browser-only        | Desktop-only         | Cross-platform      |
|------------------|---------------------|----------------------|---------------------|
| **Library (one language)**   | WebLLM, Transformers.js | `node-llama-cpp`, `llama-cpp-python` | QVAC (JS-only) |
| **Library (multi-language)** | — | — | **DVAI-Bridge** |
| **Product**      | —                   | Ollama, LM Studio, Jan.ai | llamafile |

## DVAI-Bridge vs. QVAC

**QVAC** (Tether) is the closest project in spirit — a local AI SDK,
embedded inside the app, with an optional OpenAI HTTP wrapper. We agree
on the core idea. We split on the surface.

- **Languages.** QVAC is JavaScript-only — Node, Bare, Expo, Electron. DVAI-Bridge ships native SDKs in Swift, Kotlin, Dart, TypeScript, and C#.
- **Mobile path.** QVAC reaches iOS and Android only through React Native (Expo). DVAI-Bridge has first-class Swift Package, Android AAR, and Flutter pub.dev packages.
- **OpenAI HTTP.** QVAC ships the OpenAI wrapper as an *optional* layer on a typed JS SDK. DVAI-Bridge ships the OpenAI HTTP surface as **the** product — every SDK exposes the same `127.0.0.1:38883` wire.
- **Engines.** QVAC ships Fabric LLM, customized GGML, Whisper, Diffusion, ONNX, Bergamot. DVAI-Bridge ships llama.cpp, Apple Foundation Models, MLX, CoreML, MediaPipe LLM, LiteRT — including engines QVAC doesn't reach.
- **Capabilities QVAC has and we don't yet.** Image and video generation, dedicated text-to-speech, OCR, out-of-the-box translation. On the roadmap.
- **Licence.** QVAC is Apache 2.0. DVAI-Bridge is the DVAI Bridge Community Licence — source-available with commercial terms.

If your whole stack is JavaScript and you need diffusion or TTS today,
QVAC is the natural fit. If you need native iOS, Android, Flutter, or
.NET — or you want OpenAI HTTP as the primary contract on every
platform — DVAI-Bridge.

## DVAI-Bridge vs. Ollama

**Ollama** is the best way to run LLMs on a dev machine. CLI, model
library, background daemon, OpenAI HTTP on `localhost:11434`.

- Ollama is a **product** the user installs. DVAI-Bridge is a **library** your app ships.
- You can't bundle Ollama inside your iOS, Android, or Electron app.
- Same OpenAI wire, though — code that runs against Ollama in dev runs against DVAI-Bridge in production unchanged.

Use both. Ollama on your laptop. DVAI-Bridge in the app you ship.

## DVAI-Bridge vs. llama.cpp + `llama-server`

**llama.cpp** is the canonical local LLM engine. `llama-server` is its
OpenAI-shaped HTTP binary.

- llama.cpp is the engine; DVAI-Bridge consumes it as one of many backends.
- `llama-server` is a binary you run, not code you import. Bundling it inside an iOS, Android, or Flutter app means owning cross-platform binary distribution, port management, lifecycle, and model bundling — every job DVAI-Bridge already does for you.

If you're writing a C++ server, use llama.cpp directly. If you're
shipping a client app, you want DVAI-Bridge above it.

## DVAI-Bridge vs. LM Studio, Jan.ai, GPT4All, Msty

These are **desktop chat apps** wrapping llama.cpp. They're great
products. They aren't libraries.

- You can't `import LM Studio`.
- You could build an LM-Studio-like app *on top of* DVAI-Bridge in a week — please do.

## DVAI-Bridge vs. WebLLM

**WebLLM** is browser-only MLC-compiled inference. Fast, JavaScript, in-process.

- WebLLM has no real HTTP server — it's a JS API.
- DVAI-Bridge uses WebLLM as one of its browser backends and adds: a real OpenAI HTTP surface (via MSW intercept in-browser), auto-recovery from WebGPU crashes, and the same code that also runs on every other platform.

Use plain WebLLM only if your app is browser-only forever.

## DVAI-Bridge vs. Transformers.js

**Transformers.js** runs ONNX models in the browser and Node. Huge model
catalog, multi-modal, very active project.

- Transformers.js is a **function library** — `pipeline()` returns a callable. No HTTP surface.
- DVAI-Bridge uses Transformers.js as a backend and adds the OpenAI HTTP wire — so your agent code stays framework-standard, not Transformers.js-specific.

## DVAI-Bridge vs. `node-llama-cpp`

**`node-llama-cpp`** is JS bindings for llama.cpp.

- No OpenAI HTTP. Node-only. Won't run in the browser, mobile, or an Electron renderer.
- DVAI-Bridge ships first-party NAPI bindings for IP discipline, plus the OpenAI wire, cross-platform reach, lifecycle, and recovery management.

Use `node-llama-cpp` if you're happy writing against its API in pure
Node. Use DVAI-Bridge if you want the wire to look the same as cloud
OpenAI.

## DVAI-Bridge vs. `llama-cpp-python` + `llama_cpp.server`

Python bindings for llama.cpp, plus an OpenAI-compatible HTTP server.

- If your whole stack is Python — FastAPI, Flask, Django — this is the right tool.
- DVAI-Bridge doesn't ship Python bindings. We're for JS / Swift / Kotlin / Dart / C# apps.

## DVAI-Bridge vs. `llama-cpp-capacitor`

A community Capacitor plugin for llama.cpp.

- It's a JS API, not an HTTP surface.
- DVAI-Bridge ships its own first-party Capacitor plugin (`@dvai-bridge/capacitor`) with the OpenAI HTTP server built in — point any OpenAI client at the returned URL.

## DVAI-Bridge vs. llamafile

**llamafile** packages a model + llama.cpp into one cross-platform
executable.

- It's a *distribution artifact* — one file, one model.
- You can't `import` it. Useful for sharing a model with a friend. Not for building a product.

## DVAI-Bridge vs. vLLM, TensorRT-LLM, TGI, SGLang

Production-grade inference servers for hosted fleets.

- They host inference at scale behind a load balancer.
- DVAI-Bridge runs on the user's device.

Some teams use both — vLLM for the cloud tier, DVAI-Bridge for the
offline / private tier. The agent code is identical because the wire is
identical.

## DVAI-Bridge vs. LiteLLM, OpenRouter, Portkey

**Proxies and routers.** They forward OpenAI-shaped calls across cloud
providers.

- They aren't inference engines. They route to engines.
- A LiteLLM config can point at a DVAI-Bridge endpoint as one of its backends — "local for privacy-flagged requests."

Combining them is natural.

## When not to use DVAI-Bridge

We aren't right for every job. The honest list:

- **You're doing local dev on your laptop with a CLI / chat UI** — use Ollama.
- **Your whole stack is Python** — use `llama-cpp-python`.
- **You need maximum production throughput for a fleet** — use vLLM, TensorRT-LLM, or TGI.
- **You have a cloud provider and your users don't need offline / private AI** — keep using OpenAI or Anthropic.
- **Browser-only demo, no plans for native** — plain WebLLM or Transformers.js.
- **React Native ≤ 0.73, Bridgeless OFF** — our TurboModule needs RN ≥ 0.77.

## When DVAI-Bridge is the clear answer

- You're building an app — Electron, Capacitor, native iOS, native Android, React Native, Flutter, or .NET.
- Your users should not install anything beyond your app.
- Your agent code should stay standard — LangChain, the OpenAI SDKs, Vercel AI SDK — not tied to one engine's API.
- The same code path should work across every platform you ship to.
- Cost per token is zero. Privacy is a first-class requirement.

Three or more true? DVAI-Bridge is the fastest path from prototype to
shipped.
