# DVAI-Bridge vs. the local-AI landscape

DVAI-Bridge occupies a spot in the local-AI ecosystem that, as of 2026,
no other project fully covers. This page explains where each tool fits
so you can pick the right one for your problem — including when that's
not DVAI-Bridge.

## TL;DR

If you're **building and shipping an application** (Electron, mobile,
native desktop, web) and you want local AI inside it, **without asking
your users to install anything else**, you want DVAI-Bridge.

If you're a developer or power user running local models on your own
machine, you want Ollama, LM Studio, or Jan.ai. That's not what
DVAI-Bridge is for.

## The two axes that matter

Local-AI projects usually sit on two axes:

1. **Is it a library or a product?** A library is something a developer
   imports. A product is something a user installs.
2. **Is it cross-platform or single-platform?** Some tools run only on
   desktop, some only in the browser, some only on one OS.

The gap DVAI-Bridge fills is **library × cross-platform**:

|                  | Browser-only         | Desktop-only         | Cross-platform      |
|------------------|----------------------|----------------------|---------------------|
| **Library**      | WebLLM, Transformers.js | `node-llama-cpp`, `llama-cpp-python` | **DVAI-Bridge** |
| **Product**      | — (browser-only products rare) | Ollama, LM Studio, Jan.ai | llamafile (single-file exe) |

## Full comparison

### Ollama

**Category:** Product (user-installed daemon).
**What it does:** The best-in-class way to run LLMs on your dev machine.
Gorgeous CLI, model library, runs as a background service, exposes an
OpenAI-compatible HTTP server on `localhost:11434`.
**What it's for:** Local development, model experimentation, personal
power-user workflows.
**What it's not for:** Shipping inside a product. Your app can't bundle
Ollama — your users have to install it themselves.

**DVAI-Bridge vs. Ollama:** We are not trying to replace Ollama on your
laptop; we are trying to let you *ship what you prototyped against
Ollama*. Many DVAI-Bridge users will continue to use Ollama locally for
development. In fact: if you point the OpenAI SDK at
`http://localhost:11434/v1` today and at `dvai.baseUrl` in production,
the code is identical — that's the whole point.

### llama.cpp + `llama-server`

**Category:** Inference engine (`llama.cpp`) + separate server binary
(`llama-server`).
**What it does:** The canonical, high-performance local LLM inference
engine. Written in C++. Powers most other projects in this table. Ships a
`llama-server` binary that exposes an OpenAI-compatible HTTP endpoint.
**What it's for:** Being the engine under every other project; power
users running models with fine-grained control.
**What it's not for:** Being a drop-in library. `llama-server` is a
binary you run, not code you import. If you want to ship it with your
app, you become a maintainer of cross-platform binary distribution,
port management, lifecycle wiring, and model bundling — all the things
DVAI-Bridge does for you.

**DVAI-Bridge vs. llama.cpp:** We *consume* llama.cpp. It's the native
backend across Phases 2-4. Our value-add is everything above it — the
OpenAI HTTP surface, the cross-platform library packaging, lifecycle,
the fact that you don't need to think about which accelerator is
available on which device.

### LM Studio, Jan.ai, GPT4All, Msty

**Category:** Products (desktop apps wrapping llama.cpp).
**What they do:** End-user desktop apps with chat UIs, model browsers,
one-click installs. LM Studio also exposes an OpenAI-compatible HTTP
endpoint that lives as long as the LM Studio process does.
**What they're for:** Non-technical users who want ChatGPT-like
experience offline. Power users who want a polished desktop UI.
**What they're not for:** Being a dependency your app can rely on. You
can't bundle LM Studio inside your Electron app.

**DVAI-Bridge vs. these:** They're products; we're a library. Orthogonal.
An Electron app built with DVAI-Bridge could easily compete with LM
Studio's feature set — in fact, we'd love to see it happen.

### WebLLM (MLC-AI)

**Category:** JavaScript library (browser-only).
**What it does:** Runs MLC-compiled models in the browser via WebGPU.
Has an in-process JS API that looks OpenAI-shaped (`engine.chat.completions.create(...)`),
but does *not* run a real HTTP server.
**What it's for:** Browser-only AI apps; the highest-performance in-browser
inference option for supported models.
**What it's not for:** Anything outside a browser tab. Can't run in
Node or Electron main. Can't be called from a Web Worker the way a real
HTTP endpoint can. Requires MLC-compiled model artifacts (smaller
catalog than HuggingFace).

**DVAI-Bridge vs. WebLLM:** We use WebLLM as one of our browser backends.
Our value-add over directly using WebLLM: (1) a real OpenAI HTTP surface
that any SDK can target (including via MSW in-browser); (2) automatic
recovery from WebGPU crashes; (3) the same code also works in Node,
Electron, Capacitor, etc. Use plain WebLLM if your app is browser-only
and you're comfortable wiring the OpenAI-compat layer yourself.

### Transformers.js (Hugging Face)

**Category:** JavaScript library (browser + Node).
**What it does:** Runs ONNX models via ONNX Runtime, with WebGPU in the
browser and `onnxruntime-node` in Node. Massive model variety, multiple
modalities (text, image, audio, video), very active project.
**What it's for:** In-browser and in-Node AI inference with broad model
compatibility.
**What it's not for:** Exposing an OpenAI HTTP surface — it's a function
library. You call `pipeline(...)`, you get a callable, you call it with
inputs.

**DVAI-Bridge vs. Transformers.js:** We use Transformers.js as our
default cross-browser-and-Node backend. Our value-add: the OpenAI HTTP
surface so your agent code is framework-standard (LangChain, Vercel AI
SDK, etc.) instead of Transformers.js-specific. Plus the transport
abstraction, port management, lifecycle.

### `node-llama-cpp`

**Category:** Node.js bindings for llama.cpp.
**What it does:** Gives Node programs a JS API over llama.cpp. Supports
prompt/response, chat, embeddings, grammar-guided output.
**What it's for:** Server-side Node programs that want native llama.cpp
performance.
**What it's not for:** Exposing OpenAI HTTP. Doesn't run in the browser.
Doesn't run on mobile. Not shippable inside an Electron renderer.

**DVAI-Bridge vs. `node-llama-cpp`:** We will eventually ship our own
NAPI bindings (Phase 2) rather than depending on `node-llama-cpp`, for
IP-discipline reasons. From a developer's perspective, DVAI-Bridge adds
(1) the OpenAI HTTP surface, (2) cross-platform (same library works in
browser/mobile/etc), (3) lifecycle + port + recovery. `node-llama-cpp`
is lower-level and more flexible for pure Node use cases where you're
happy to write against its API directly.

### `llama-cpp-python` + `llama_cpp.server`

**Category:** Python bindings for llama.cpp, with an optional
OpenAI-compatible server module.
**What it does:** Python equivalent of `node-llama-cpp`, plus a Python
OpenAI-compatible HTTP server.
**What it's for:** Python server applications — FastAPI / Flask / Django
apps that want local inference.
**What it's not for:** Non-Python apps. Can't embed it inside an iOS
app or a .NET desktop app.

**DVAI-Bridge vs. `llama-cpp-python`:** Closest functional competitor,
but different language and different deployment shape. If your whole
stack is Python, use `llama-cpp-python`. If you're shipping client apps
(Electron, mobile, native desktop), DVAI-Bridge.

### `llama-cpp-capacitor`

**Category:** Capacitor plugin (iOS + Android bindings for llama.cpp).
**What it does:** Lets a Capacitor app call llama.cpp from JS.
**What it's for:** Mobile hybrid apps wanting on-device inference.
**What it's not for:** Exposing OpenAI HTTP; cross-platform beyond
Capacitor; a drop-in OpenAI-surface library.

**DVAI-Bridge vs. `llama-cpp-capacitor`:** DVAI-Bridge v1.5 used
`llama-cpp-capacitor` as its mobile backend; Phase 1 replaces it with
first-party bindings and adds the embedded HTTP server story (so you
point your OpenAI SDK at it instead of using a mobile-specific JS API).

### llamafile (Mozilla Ocho)

**Category:** Single-file executable.
**What it does:** Packages a model plus llama.cpp into one cross-platform
executable that also serves an OpenAI-compatible endpoint.
**What it's for:** "Run this model as a server, no install, no build."
Portable demos, single-binary deployments.
**What it's not for:** Being a dependency of another application.
You can't `import llamafile` — it's a binary.

**DVAI-Bridge vs. llamafile:** Different tool, different job. Llamafile
is a *distribution artifact* (one file → one model). DVAI-Bridge is a
*library* (import → your app spawns a server internally). You might
use llamafile to share a model with a friend. You use DVAI-Bridge to
ship a product.

### vLLM, TensorRT-LLM, TGI, SGLang

**Category:** Production-grade server stacks.
**What they do:** High-throughput inference servers for running a fleet
behind a load balancer. Batch processing, paged attention, speculative
decoding, etc.
**What they're for:** Hosting inference at scale for many concurrent
users.
**What they're not for:** Embedding inside a client app. They're servers
you deploy on hardware you control.

**DVAI-Bridge vs. these:** Orthogonal. If you're building a SaaS,
you probably want vLLM behind your API. If you're building a client-side
app that needs AI without a backend, you want DVAI-Bridge. Some orgs
will use both — vLLM for the bulk tier, DVAI-Bridge for the privacy /
offline tier.

### LiteLLM, OpenRouter, Portkey

**Category:** Proxies / routers.
**What they do:** Forward OpenAI-shaped calls to 100+ model providers;
handle fallback, caching, cost tracking.
**What they're for:** Orchestrating calls across cloud providers.
**What they're not for:** Local inference. They're routers, not engines.

**DVAI-Bridge vs. these:** Again orthogonal. You could point a LiteLLM
config at a DVAI-Bridge endpoint as one of its backends — "local as a
fallback" or "local for privacy-flagged requests." Combining them is
natural.

## When you should NOT use DVAI-Bridge

Being honest about when we're wrong for a job:

- **You're doing local development on your laptop and you want a CLI /
  model browser / chat UI.** Use Ollama. It's better at that.
- **Your whole stack is Python.** Use `llama-cpp-python`. Fewer moving
  parts for you.
- **You need the maximum possible throughput for a production fleet.**
  Use vLLM / TensorRT-LLM / TGI on dedicated hardware. DVAI-Bridge is
  optimized for single-user on-device, not many-user many-GPU.
- **You already have a cloud provider and your users don't need
  offline / private AI.** Keep using OpenAI / Anthropic / Google. The
  DVAI-Bridge value proposition assumes on-device is a requirement.
- **You're writing a browser-only demo and will never need Node /
  Electron / mobile.** Plain WebLLM or Transformers.js works fine —
  saves you one dependency.

## When DVAI-Bridge is the clear answer

- You're building an Electron, Tauri, Capacitor, React Native, Flutter,
  native mobile, or native desktop application.
- Your users should not have to install anything beyond your app.
- Your agent code should stay standard (LangChain, OpenAI SDK, Vercel
  AI SDK) rather than locking into any particular inference engine's API.
- You want the same code to work across every platform you ship to.
- Cost per token is zero and privacy is a first-class requirement.

If three or more of the above are true, DVAI-Bridge is the fastest path
from prototype to shipped.
