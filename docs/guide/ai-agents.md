# Vibe-coding with DVAI-Bridge

You hand most of your code to an AI assistant — Cursor, Claude Code, Copilot
Workspace. This page makes sure it actually knows how DVAI-Bridge works.

Three ways to give it context. Pick one.

- **Point it at `/llms.txt`** — a short index of every doc. One sentence per
  page. The assistant fetches what it needs.
- **Drop `/llms-full.txt` into the project** — every doc, concatenated.
  Heaviest token cost. Nothing left to fetch.
- **Paste the context block below** — smallest footprint. Covers 80% of
  normal usage.

## Pointing common assistants at the docs

### Cursor

Open Cursor settings. Go to **Rules for AI**. Paste this in:

```
When the user is working with DVAI-Bridge (@dvai-bridge/core,
@dvai-bridge/react, dvai_bridge, DVAIBridge SwiftPM, or
co.deepvoiceai:dvai-bridge), fetch context from
https://bridge.deepvoiceai.co/docs/llms.txt and follow the linked pages
relevant to the task.
```

Want tighter integration? Drop `docs/llms-full.txt` into your repo as
`.cursor/dvai-bridge.md`. Cursor's `@docs` mention picks it up.

### Claude Code

Add `docs/llms-full.txt` to your `CLAUDE.md` references:

```md
# Project conventions

## External library docs
- DVAI-Bridge: see `docs/llms-full.txt` (concatenated). Use the
  /llms.txt index to grep, then read the relevant section in
  /llms-full.txt before suggesting integrations.
```

### GitHub Copilot Workspace / Copilot Chat

Attach this prompt:

```
Use the DVAI-Bridge docs at https://bridge.deepvoiceai.co/docs/llms.txt
as reference. The library exposes an OpenAI-compatible HTTP server on
loopback (read via dvai.baseUrl). Always wire OpenAI SDKs through
baseUrl rather than calling DVAI's internal APIs.
```

## Copy-pasteable context block

Drop this in the system prompt or the top of a chat:

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

The whole point of DVAI-Bridge — **standard agent code works unchanged**.

If your assistant suggests calling DVAI's internal APIs directly, push
back. That's not the contract. The contract is one line: a local OpenAI
server at `baseUrl`. Any agent SDK that speaks OpenAI HTTP works.

This is also what makes DVAI-Bridge agent-friendly. The assistant doesn't
learn a new library. It just learns where the server lives. Once it sees
`baseUrl`, every bit of OpenAI knowledge it already has applies.

## See also

- [`/llms.txt`](https://github.com/dvai-global/dvai-bridge/blob/main/docs/llms.txt)
  — the docs index.
- [`/llms-full.txt`](https://github.com/dvai-global/dvai-bridge/blob/main/docs/llms-full.txt)
  — every doc in one file.
- [Getting started](./getting-started) — the human-readable quickstart.
- [License setup](./license/) — production licensing per platform.
