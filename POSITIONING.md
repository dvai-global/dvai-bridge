# DVAI-Bridge — Positioning

> **Status:** Internal. Not published with the library. Single source of truth
> for how we describe this project to the world.

---

## One-line pitch

**The local OpenAI server you embed inside your app.**

(Alternate phrasings for context:
"Your app ships with Ollama built in."
"The embedded OpenAI endpoint for every stack.")

## The elevator (30 seconds)

Developers prototype local AI agents against Ollama and LangChain on their
laptop. Then they try to ship, and they hit a wall: Ollama is a separate
install. Their users don't have it. Their mobile app can't run it. Their
corporate policy forbids adding another daemon.

DVAI-Bridge fixes that. It's a library you import — in JavaScript, Swift,
Kotlin, or C#. On `initialize()` (or `start()`), it spins up a real
OpenAI-compatible HTTP server *inside your app process*, backed by local
inference, on every platform that matters — web, Node, Electron, iOS,
Android, .NET desktop. Your agent code doesn't change. Your users don't
install anything. No cloud, no keys, no costs.

## The problem (for a developer audience)

1. **Local AI development tooling is great.** Ollama, LM Studio, llama.cpp's
   server, WebLLM — developers love building with them.

2. **Local AI shipping tooling is broken.** Nothing you build with those tools
   actually ships inside an app. The user has to install Ollama separately.
   Your mobile app can't spawn a daemon. Your desktop app has to ship
   llama.cpp as a sidecar binary and reinvent port management, lifecycle,
   OpenAI HTTP translation.

3. **The gap is a library-shaped hole — across every major language.** Every
   production app that wants local AI ends up reinventing the same plumbing:
   start an inference engine, expose an OpenAI-compatible HTTP surface, bind
   to a port that isn't taken, handle CORS for webviews, shut it down on
   unload, wrap the platform's accelerator of the day. And every language
   ecosystem has to do it again from scratch.

4. **DVAI-Bridge is that library, everywhere.** One contract: the OpenAI
   HTTP endpoint on loopback. Six packages — `@dvai-bridge/core` for JS,
   `@dvai-bridge/capacitor` for hybrid mobile, a Swift Package for iOS, an
   AAR for Android, a NuGet for .NET. Point your OpenAI SDK of choice at the
   returned URL. Same across every platform.

## What DVAI-Bridge IS

- **A library, not a product.** Developers import it. It has no UI, no CLI
  meant for end users, no daemon.
- **An OpenAI HTTP server implementation.** The entire public surface is the
  OpenAI-compatible REST API on loopback. Developers talk to it with the
  OpenAI SDK of their choice (any language with HTTP).
- **Cross-platform and cross-language by design.** Same contract across
  browser, Node, Electron, Capacitor mobile, Android native (Kotlin / Java),
  iOS native (Swift), and .NET desktop (C#).
- **Backend-pluggable internally.** llama.cpp, WebLLM, Transformers.js,
  CoreML, MediaPipe LLM, Apple Foundation Models, ONNX Runtime GenAI,
  LiteRT — all selectable per platform; all invisible to the agent code
  that consumes the OpenAI endpoint.
- **Our own native code.** All NAPI / JNI / Swift / ObjC++ / P/Invoke
  bindings are first-party. llama.cpp is consumed as a pinned upstream
  source drop, built into our binaries, not as a third-party wrapper
  dependency. We control the IP.

## What DVAI-Bridge is NOT

- **Not a multi-backend SDK.** We do not expose language-idiomatic APIs
  per backend. You don't write "if webllm then ... else if llama.cpp then
  ...". You write OpenAI SDK calls. That's the point.
- **Not a wrapper around llama.cpp or ONNX for convenience.** Those engines
  already exist. We don't add value by re-exposing them.
- **Not a cloud service.** No server, no relay, no telemetry. Everything
  runs on the user's device.
- **Not a replacement for Ollama on a developer's dev machine.** Ollama
  is great for local development and side-loading models. DVAI-Bridge
  is what you reach for when you need to *ship* what you prototyped.
- **Not a UI / chat product.** No "DVAI-Bridge app." It's engineering.

## Target developer personas

| Persona | What they're building | What they need from us |
|---|---|---|
| Electron app dev (Jan.ai-style, Replit desktop, Linear-alike) | Desktop app with built-in AI assistant | Ship fast, feel native, zero user setup, GPU accel when present |
| Capacitor / Ionic mobile dev | Hybrid mobile app with private AI features | Works offline, respects cellular/battery, App Store / Play Store safe |
| React Native dev | Cross-platform mobile with on-device intelligence | Native perf, no cloud dependency, same agent code as web |
| Flutter / Dart dev | Cross-platform app | FFI bindings to native, standard OpenAI interface upstream |
| Android native (Kotlin) dev | Android-first AI features | AAR with AAB ready, NNAPI / QNN accel, size-conscious |
| iOS native (Swift) dev | On-device Apple AI features | SPM package, CoreML / ANE / Metal, Apple FM framework integration |
| .NET desktop dev (WPF, WinUI, Unity) | Enterprise / game AI | NuGet, DirectML, ONNX Runtime GenAI option |
| Web / Next.js dev | Browser-first AI web app | WebGPU perf, works offline (PWA), no backend required |

Every persona above is a first-class target as of public launch. The
only partial cases are React Native and Flutter — both can use our iOS
Swift Package and Android AAR directly through standard native-bridge
patterns, with dedicated RN / Flutter wrapper packages on the near-term
roadmap.

## Differentiation (short form — full comparison lives in `docs/guide/comparison.md`)

| Project | Category | What it does | What it doesn't |
|---|---|---|---|
| **Ollama** | Product (user-installed) | Best-in-class local AI daemon for dev machines | Your app can't ship Ollama; end users must install it |
| **llama.cpp / `llama-server`** | Engine + binary | Reference inference engine; a server binary exists | Not a library; no mobile / browser story; you wire it yourself |
| **LM Studio / Jan.ai / GPT4All** | Product | Desktop apps wrapping llama.cpp | User-facing products, not libraries to embed |
| **WebLLM / Transformers.js** | Browser JS libs | In-browser WebGPU inference | Browser only; no real HTTP server; no server stack |
| **`node-llama-cpp` / `llama-cpp-capacitor`** | Language bindings | Bindings for one runtime | No HTTP server; single language; you reimplement the OpenAI surface |
| **`llama-cpp-python` + `llama_cpp.server`** | Python bindings + server | Closest competitor | Python only; not cross-platform; not bundled inside another app |
| **llamafile** | Single-file exe | Neat portability trick | Not a library; not cross-platform as a dep |
| **DVAI-Bridge** | Library (multi-language) | Embeds a local OpenAI server in your app across JS, Swift, Kotlin, and C# | Not a standalone product; not a backend |

**The one-sentence difference:** *every other project either is not a
library, or is not cross-platform, or is single-language. DVAI-Bridge is
all three.*

## Non-goals (from the technical spec; reinforced)

- We will not expose language-idiomatic SDK wrappers beyond the minimum
  `start() → url / stop()` lifecycle. The OpenAI HTTP surface IS the idiom.
- We will not take a runtime dependency on third-party NAPI / JNI / FFI
  wrappers. Every binding is first-party.
- We will not bundle every accelerator variant into the distributed
  package. Lazy download on first run by platform + architecture + GPU,
  with checksum verification — same pattern Ollama uses.
- We will not ship our own UI, chat app, or hosted inference service.

## How we got here (condensed engineering history)

DVAI-Bridge was built in four overlapping phases over the course of 2026:

- **Phase 0 — Transport abstraction + HTTP server.** Handler logic
  extracted from MSW into a transport-agnostic module; real
  `http.createServer` transport for Node / Electron main; port-fallback
  policy (base `38883` + up to 16 attempts); CORS + Private Network
  Access on every response; equivalence test proving MSW and HTTP
  transports produce the same response shape.
- **Phase 1 — Capacitor mobile multimodal.** First-party iOS + Android
  plugin that boots an embedded HTTP server on-device, backed by
  llama.cpp with our own Swift + Kotlin bindings. Multimodal (vision
  via mmproj; Whisper preprocessing for audio where needed).
- **Phase 2 — Electron bundled binary via our own NAPI.** llama.cpp built
  from pinned upstream source into per-platform shared libraries with
  CUDA / Metal / Vulkan / DirectML variants. Lazy binary download +
  checksum verification — no bloat in the npm tarball.
- **Phase 3 — Native host-platform bindings.** Android AAR (Kotlin + JNI
  to our first-party llama.cpp build), iOS Swift Package (ObjC++ bridge
  to Metal-accelerated llama.cpp + Apple Foundation Models / CoreML),
  .NET NuGet (P/Invoke + ONNX Runtime GenAI + optional DirectML). Each
  binding exposes a tiny `start() → port / stop()` lifecycle — the real
  API is the HTTP endpoint on every platform.

## Post-launch roadmap

- **Cross-framework wrappers.** Dedicated React Native and Flutter
  packages that boot the underlying native server and expose the port
  to the app layer — both platforms work today via standard native-bridge
  patterns; dedicated wrappers reduce the boilerplate.
- **Debug / introspection endpoint.** Opt-in `GET /_debug/recent-requests`
  for in-app diagnostic UIs.
- **Expanded backends.** Apple Foundation Models deeper integration, MLX,
  and platform-specific accelerator experiments as they mature.

## What we want to be known for

- "If your app needs on-device AI, you reach for DVAI-Bridge first —
  regardless of what language you write your app in."
- The name that comes up in the first Stack Overflow answer when someone
  asks "how do I ship a local LLM inside my Electron / iOS / Android / .NET app?"
- The library that Jan.ai, Raycast, Linear, Superhuman, and every new
  AI-native desktop / mobile product depends on instead of writing their
  own sidecar.

## Tone and voice

- **Confident, not cocky.** We solve a real problem. State it plainly.
- **Developer-first.** Lead with code. Follow with architecture. Avoid
  marketing adjectives ("revolutionary", "next-generation", "AI-powered
  platform") — developers smell them from a mile off.
- **Honest about tradeoffs.** If Ollama is better for dev workflow, say so.
  If llama.cpp is a better low-level engine, say so. Our claim is narrow
  and defensible — we don't need to bludgeon.
- **Cross-platform but not platform-neutral.** Respect each platform's
  idioms. The iOS section reads like Apple documentation; the Android
  section reads like Google's. Not copy-paste sameness.
- **Never claim benchmarks we haven't run.** Don't promise "2× faster than
  Ollama" unless we've measured. We probably aren't faster — we're
  embeddable and cross-language, which are different axes entirely.

## One-page pitch (for investor / partner conversations)

We build the universal local-AI server for apps. Today, if you want to add
offline AI to your product, you either host it yourself (expensive,
privacy-hostile, infrastructure-heavy) or you tell your users to install
Ollama (usually not acceptable) — and if your app isn't in JavaScript,
you're largely on your own. DVAI-Bridge is a library that embeds a local
OpenAI-compatible server directly inside your application, across every
major client-development language: JavaScript, Swift, Kotlin, and C#.
Web, mobile, desktop, native. No install step for the user. We own the
entire native-code stack (first-party bindings, pinned-source llama.cpp,
no third-party NAPI / JNI / FFI wrappers). Licensed dual: free for
development, commercial license for production. Market: every developer
building an AI-powered app who currently has to choose between the cloud
tax and the "please install Ollama" message — regardless of their stack.
