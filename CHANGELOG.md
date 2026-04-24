# Changelog

All notable changes to this project are documented here. This project
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.6.0] — 2026-04-24

Phase 0 — Transport Abstraction: extracts the OpenAI-compatible handlers
into a transport-agnostic module and adds a real HTTP server transport
for Node / Electron. The browser path (MSW) is behaviorally unchanged.

### Added
- `transport` config option: `"auto" | "msw" | "http" | "none"`.
- HTTP transport for Node and Electron main process (base port `38883`,
  +1 fallback up to 16 attempts on `EADDRINUSE`).
- `dvai.baseUrl` / `dvai.port` fields.
- `dvai.getBaseUrl()` / `dvai.getPort()` / `dvai.getActiveTransport()` methods.
- New transport-agnostic handler module under `src/handlers/`
  (`handleChatCompletion`, `handleCompletion`, `handleEmbeddings`,
  `handleModels` as pure `(body, ctx) => Response` functions).
- CORS + Private Network Access headers on HTTP transport responses
  (enables HTTPS pages calling loopback without Chrome/Edge PNA blocks).
- `BASE_PORT` and `MAX_PORT_ATTEMPTS` exported constants from
  `@dvai-bridge/core` (via `./transports`).
- `httpBasePort`, `httpMaxPortAttempts`, `corsOrigin` config options.
- Root-level `examples/` directory (`web-react`, `node-langchain`) —
  moved out of the published package path.
- `files` allowlist on all package `package.json` files — prevents
  `src/`, `example/`, and test files from accidentally shipping to npm.

### Changed
- `mockUrl` is now MSW-specific. Under HTTP transport, it is ignored
  with a one-time console warning. Read `dvai.baseUrl` for the real URL.
- `DVAI` in Node now auto-starts a real HTTP server on `initialize()`
  (previously crashed trying to register MSW without
  `navigator.serviceWorker`).
- Internal `buildMswHandlers` refactored into pure handler functions
  plus a thin MSW transport adapter (`MswTransport` class).
- `HandlerContext.backend` is now exposed via a getter so mid-request
  recovery can swap the backend instance and subsequent handler calls
  see the new one. Not a user-facing change.

### Removed
- `packages/dvai-bridge-core/example/langchain-node-example.js` standalone
  snippet (replaced by the runnable `examples/node-langchain/` project).
- `DVAI.getWorker()` method (the MSW worker is now an implementation
  detail of `MswTransport`; read `dvai.getBaseUrl()` instead).

### Fixed
- `new DVAI()` in plain Node no longer crashes — auto-resolves to the
  new HTTP transport.

### Migration guide: 1.5.x → 1.6.0

**Browser consumers (React / Vanilla):** no action required.
`new DVAI({})` continues to use MSW in browsers with identical behavior.

**Node / Electron consumers:** `DVAI` now auto-boots an HTTP server at
`http://127.0.0.1:38883/v1`. Read `dvai.baseUrl` and pass it to your
OpenAI SDK:

```javascript
const dvai = new DVAI({ backend: "transformers" });
await dvai.initialize();
// dvai.baseUrl === "http://127.0.0.1:38883/v1" (or 38884, 38885, ...)

const openai = new OpenAI({ baseURL: dvai.baseUrl, apiKey: "ignored" });
```

If you want the old direct-inference-only behavior (no transport),
pass `transport: "none"` explicitly, or keep using `serviceWorkerUrl: ""`.

**Custom `mockUrl` + HTTP:** `mockUrl` is ignored under HTTP transport.
If you need a specific URL shape, stay on MSW (`transport: "msw"`,
browser only), or read `dvai.baseUrl` at runtime.

**Removed `getWorker()`:** if you depended on direct access to the MSW
worker instance, that's no longer exposed. Use `dvai.baseUrl` for the
endpoint URL, or `dvai.getActiveTransport()` to check which transport
is active.
