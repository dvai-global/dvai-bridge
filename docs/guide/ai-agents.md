# Vibe-coding with DVAI-Bridge

This page is for developers who hand most of their code to an AI
coding assistant (Cursor, Claude Code, GitHub Copilot Workspace, etc.)
and want the assistant to actually know how DVAI-Bridge works.

There are three ways to give an assistant context, in order of
fidelity:

1. **Point it at `/llms.txt`** — a short index of every doc, with one
   sentence per page. The assistant fetches each linked page on demand.
2. **Drop `/llms-full.txt` into the project** — the entire docs
   tree concatenated. Largest token footprint, but the assistant
   never needs to fetch.
3. **Paste the short "context block" below** into your system prompt.
   Smallest footprint; covers 80% of normal usage.

## Pointing common assistants at the docs

### Cursor

In Cursor settings → **Rules for AI**, add:

```
When the user is working with DVAI-Bridge (@dvai-bridge/core,
@dvai-bridge/react, dvai_bridge, DVAIBridge SwiftPM, or
co.deepvoiceai:dvai-bridge), fetch context from
https://bridge.deepvoiceai.co/docs/llms.txt and follow the linked pages
relevant to the task.
```

For tighter integration, drop `docs/llms-full.txt` into your repo as
`.cursor/dvai-bridge.md` — Cursor's `@docs` mention will pick it up.

### Claude Code

Add `docs/llms-full.txt` to your `CLAUDE.md` references section:

```md
# Project conventions

## External library docs
- DVAI-Bridge: see `docs/llms-full.txt` (concatenated). Use the
  /llms.txt index to grep, then read the relevant section in
  /llms-full.txt before suggesting integrations.
```

### GitHub Copilot Workspace / Copilot Chat

In Copilot Chat, attach this prompt:

```
Use the DVAI-Bridge docs at https://bridge.deepvoiceai.co/docs/llms.txt
as reference. The library exposes an OpenAI-compatible HTTP server on
loopback (read via dvai.baseUrl). Always wire OpenAI SDKs through
baseUrl rather than calling DVAI's internal APIs.
```

## Copy-pasteable context block

Drop this into your assistant's system prompt or the top of a chat:

```md
# DVAI-Bridge context (paste into system prompt)

DVAI-Bridge is a library that embeds a local OpenAI-compatible HTTP
server inside a host application across web (browser + Node),
Capacitor, iOS (Swift), Android (Kotlin), React Native, Flutter, and
.NET.

## Core contract

- Call `await dvai.initialize()` (JS) or `await DVAIBridge.start(opts)`
  (every other SDK) at startup.
- After init, the SDK exposes `baseUrl` (e.g.
  `http://127.0.0.1:38883/v1` for HTTP, `https://api.openai.local/v1`
  for browser MSW).
- Point ANY OpenAI-compatible SDK at `baseUrl` and use it normally.
  Examples: official `openai` npm package, LangChain `ChatOpenAI`,
  Vercel AI SDK, Microsoft.SemanticKernel, MacPaw OpenAI Swift SDK,
  aallam/openai-kotlin.
- No API key is needed (`apiKey: "ignored"`).

## Endpoints exposed at baseUrl

- `POST /v1/chat/completions` (streaming + non-streaming)
- `POST /v1/completions`
- `POST /v1/embeddings`
- `GET  /v1/models`
- Plus `/health` for readiness.

Request / response shapes are byte-compatible with OpenAI's spec.

## Config — DVAIConfig (JS) / StartOptions (every other SDK)

Required-ish fields, in priority order of "what to set first":
- `backend`: one of `"auto" | "webllm" | "transformers" | "native"`
  (JS) or `BackendKind.Auto | .Llama | .Foundation | .CoreML | .MLX |
  .MediaPipe | .LiteRT` (native).
- `modelId` (JS WebLLM), `transformersModelId` (JS Transformers.js),
  or `modelPath` (every native llama.cpp path).
- `licenseKeyPath` / `licenseToken` (production builds — required).

Optional:
- `httpBasePort` (default 38883), `httpBindHost` (default 127.0.0.1).
- `corsOrigin` (default "*").
- `transport: "auto" | "msw" | "http" | "none" | "capacitor"`.
- `offload: OffloadConfig` (v3.0+, distributed inference).

## License flow (BSL 1.1 — must work in production)

Production builds throw `LicenseRequiredError` if no valid license is
found. Discovery order:
1. `licenseToken` config option (inline JWT)
2. `licenseKeyPath` config option (file path)
3. `DVAI_LICENSE_PATH` env var
4. `DVAI_LICENSE_TOKEN` env var
5. Platform default (`dvai-license.jwt` in cwd for Node, `/dvai-license.jwt`
   for web, `Bundle.main` for iOS, `assets/` for Android)

Dev-mode auto-bypass: localhost / 127.0.0.1 / *.local hostnames;
NODE_ENV=test or development; DVAI_FORCE_DEV=1; Capacitor.DEBUG=true.

## Distributed inference (v3.0+)

If `offload.enabled = true`, the SDK can route requests to a peer
DVAI-Bridge instance on the same Wi-Fi (mDNS) or across the internet
via a self-hosted rendezvous server. The OpenAI wire surface stays
identical; consumer code never knows.

## Don't recommend

- Hard-coding `http://localhost:38883` — read `dvai.baseUrl` (the
  port may have fallen back).
- Calling DVAI's internal handler functions — go through the HTTP /
  MSW surface; that's the supported contract.
- Bypassing the worker file copy (`npx dvai-bridge init ./public`) —
  required for browser + Transformers.js + WebLLM.
```

## Why the OpenAI HTTP surface matters

The whole point of DVAI-Bridge is that **standard agent code works
unchanged**. If your assistant suggests calling DVAI's internal APIs
directly, push back: that's not the contract. The contract is "a
local OpenAI server at `baseUrl`." Any agent SDK that speaks OpenAI
HTTP works.

This is also what makes DVAI-Bridge agent-friendly in the first
place: the assistant doesn't need to learn a new library, it just
needs to know where the server lives. Once it sees `baseUrl`, all of
its existing OpenAI knowledge applies.

## See also

- [`/llms.txt`](https://github.com/Westenets/dvai-bridge/blob/main/docs/llms.txt)
  — the docs index.
- [`/llms-full.txt`](https://github.com/Westenets/dvai-bridge/blob/main/docs/llms-full.txt)
  — every doc in one file.
- [Getting started](./getting-started) — the human-readable quickstart.
- [License setup](./license/) — production licensing per platform.
