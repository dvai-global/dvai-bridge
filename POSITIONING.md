# DVAI-Bridge — Positioning

> **Status:** Internal. Not published with the library. Single source of truth
> for how we describe this project to the world.

---

## One-line pitch

**The local OpenAI server you bundle inside your app.**

(Alternate phrasings for context:
"Your app ships with Ollama built in."
"The embedded OpenAI endpoint for every stack.")

## The elevator (30 seconds)

Developers prototype local AI agents against Ollama and LangChain on their
laptop. Then they try to ship, and they hit a wall: Ollama is a separate
install. Their users don't have it. Their mobile app can't run it. Their
corporate policy forbids adding another daemon.

DVAI-Bridge fixes that. It's a library you import. On `initialize()`, it spins
up a real OpenAI-compatible HTTP server *inside your app process*, backed by
local inference, on every platform that matters — web, Node, Electron,
iOS, Android, .NET. Your agent code doesn't change. Your users don't install
anything. No cloud, no keys, no costs.

## The problem (for a developer audience)

1. **Local AI development tooling is great.** Ollama, LM Studio, llama.cpp's
   server, WebLLM — developers love building with them.

2. **Local AI shipping tooling is broken.** Nothing you build with those tools
   actually ships inside an app. The user has to install Ollama separately.
   Your mobile app can't spawn a daemon. Your desktop app has to ship
   llama.cpp as a sidecar binary and reinvent port management, lifecycle,
   OpenAI HTTP translation.

3. **The gap is a library-shaped hole.** Every production app that wants
   local AI ends up reinventing the same plumbing: start an inference
   engine, expose an OpenAI-compatible HTTP surface, bind to a port that
   isn't taken, handle CORS for webviews, shut it down on unload, wrap
   the platform's accelerator of the day.

4. **DVAI-Bridge is that library.** One API: `dvai.initialize()` →
   `dvai.baseUrl` → point your OpenAI SDK at it. Same across every
   platform. Native-speed on each. Zero install steps for end users.

## What DVAI-Bridge IS

- **A library, not a product.** Developers import it. It has no UI, no CLI
  meant for end users, no daemon.
- **An OpenAI HTTP server implementation.** The entire public surface is the
  OpenAI-compatible REST API on loopback. Developers talk to it with the
  OpenAI SDK of their choice (any language).
- **Cross-platform by design.** Same library, same contract, across browser,
  Node, Electron, Capacitor mobile, Android native, iOS native, and .NET
  desktop.
- **Backend-pluggable internally.** llama.cpp, WebLLM, Transformers.js,
  CoreML, MediaPipe LLM, Apple Foundation Models, ONNX Runtime GenAI —
  all selectable per platform; all invisible to the agent code that
  consumes the OpenAI endpoint.
- **Our own native code.** All NAPI/JNI/Swift/P-Invoke bindings are
  first-party. llama.cpp is consumed as a pinned upstream source drop,
  not as a third-party wrapper dependency. We control the IP.

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
| Android native (Kotlin) dev | Android-first AI features | AAR with AAB ready, NNAPI/QNN accel, size-conscious |
| iOS native (Swift) dev | On-device Apple AI features | SPM package, CoreML/ANE/Metal, Apple FM framework integration |
| .NET desktop dev (WPF, WinUI, Unity) | Enterprise/game AI | NuGet, DirectML, ONNX Runtime GenAI option |
| Web / Next.js dev | Browser-first AI web app | WebGPU perf, works offline (PWA), no backend required |

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
| **DVAI-Bridge** | Library | Embeds a local OpenAI server in your app across every major stack | Not a standalone product; not a backend |

**The one-sentence difference:** *every other project either is not a library or is not cross-platform. DVAI-Bridge is both.*

## Non-goals (from technical spec; keep reinforcing)

- We will not expose language-idiomatic SDK wrappers. The OpenAI HTTP surface
  IS the idiom.
- We will not take a runtime dependency on third-party NAPI / JNI / FFI
  wrappers. Every binding is first-party.
- We will not bundle every accelerator variant into the npm tarball. Lazy
  download on first run by platform + architecture + GPU, with checksum
  verification — same pattern Ollama uses.
- We will not ship our own UI, chat app, or hosted inference service.

## Roadmap at a glance

- **Phase 0 — Transport abstraction + HTTP server.** ✅ Complete (v1.6.0
  internal). Unblocks every subsequent phase.
- **Phase 1 — Capacitor mobile multimodal.** iOS + Android hybrid mobile
  via Capacitor plugin that embeds an HTTP server on-device.
- **Phase 2 — Electron bundled binary (llama.cpp via our own NAPI).** Desktop
  app story with CUDA / Metal / Vulkan acceleration.
- **Phase 3 — Native host-platform bindings.** Android AAR, iOS Swift
  Package, .NET NuGet. Each exposes a tiny `start() → port / stop()`
  lifecycle API; the real API remains the OpenAI HTTP endpoint.
- **Phase 4 — Cross-framework wrappers.** React Native + Flutter modules
  that boot the underlying native server and expose the port to the app.
- **Public launch:** end of Phase 3 — the full cross-stack story ready at
  once.

## What we want to be known for

- "If your app needs on-device AI, you reach for DVAI-Bridge first."
- The name that comes up in the first Stack Overflow answer when someone
  asks "how do I ship a local LLM inside my Electron / iOS / Android app?"
- The library that Jan.ai, Raycast, Linear, Superhuman, and every new
  AI-native desktop product depends on instead of writing their own sidecar.

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
- **Never claim benchmarks we haven't run.** Don't promise "2x faster than
  Ollama" unless we've measured. We probably aren't faster — we're
  embeddable, which is a different axis entirely.

## One-page pitch (for investor / partner conversations)

We build the universal local-AI server for apps. Today, if you want to add
offline AI to your product, you either host it yourself (expensive,
privacy-hostile, infrastructure-heavy) or you tell your users to install
Ollama (usually not acceptable). DVAI-Bridge is a library that embeds a
local OpenAI-compatible server directly inside your application — web,
mobile, desktop, any language, no install step for the user. One contract,
every platform. We own the entire native-code stack (our own bindings,
pinned-source llama.cpp, first-party Swift/Kotlin/C#). Licensed dual: free
for development, commercial license for production. Market: every developer
building an AI-powered app who currently has to choose between the cloud
tax and the "please install Ollama" message.
