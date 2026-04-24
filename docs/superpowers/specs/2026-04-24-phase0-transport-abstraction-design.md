# Phase 0 — Transport Abstraction & Real HTTP Server

**Status:** Draft — awaiting review
**Date:** 2026-04-24
**Target release:** 1.5.2 → 1.6.0
**Scope:** `@dvai-bridge/core` only (React/Vanilla wrappers unaffected)

---

## 1. Product context

`dvai-bridge` exists to replace Ollama as the local OpenAI-compatible AI server for applications that bundle their own models. The OpenAI-compatible HTTP endpoint is the single, canonical interface across every platform and language. Today `@dvai-bridge/core` only supplies this surface via MSW (browser fetch interception), which excludes Node, Electron main process, mobile native runtimes, and desktop bindings. Phase 0 makes the handler logic transport-agnostic and adds a real HTTP server transport, unblocking all downstream phases.

**Phase 0 is not about new functionality.** It is a refactor + one new transport. Behavior on the web stays identical.

## 2. Goals

1. Extract the four OpenAI-compatible handlers from `DVAI.buildMswHandlers` into a pure, transport-agnostic module.
2. Add an `http.createServer`-based transport that binds to `127.0.0.1` with a deterministic base-port-plus-fallback policy.
3. Keep `new DVAI(config).initialize()` as the single entry point. The library auto-selects the right transport for the runtime (MSW in browsers, HTTP in Node).
4. Prove equivalence with an integration test: the same request against either transport produces the same response.
5. Reorganize the repository so examples live at the root and never ship to npm.
6. Ship as a minor version bump with a clean changelog and migration notes.

## 3. Non-goals

- Introducing new AI backends (future phases).
- Electron NAPI layer (Phase 2).
- Mobile Capacitor HTTP server (Phase 1).
- Changing the MSW intercept URL or the current browser behavior.
- Aligning error responses to OpenAI's `{ error: { message, type, code, param } }` shape (deferred).
- Debug endpoint (`GET /_debug/recent-requests`) — deferred to a follow-up.

## 4. Architecture

```
                 ┌──────────────────────────────┐
                 │       DVAI (public class)    │
                 │   initialize(), baseUrl,     │
                 │   port, unload()             │
                 └───────────────┬──────────────┘
                                 │  selects at runtime
              ┌──────────────────┼──────────────────┐
              ▼                                     ▼
    ┌─────────────────┐                    ┌─────────────────┐
    │  MswTransport   │                    │  HttpTransport  │
    │  (browser only) │                    │  (node only)    │
    │  uses msw/browser                    │  uses node:http │
    └────────┬────────┘                    └────────┬────────┘
             │  both call                           │
             └──────────────┬───────────────────────┘
                            ▼
              ┌──────────────────────────┐
              │    Handler module        │
              │  handleChatCompletion()  │
              │  handleCompletion()      │
              │  handleEmbeddings()      │
              │  handleModels()          │
              │  (body, ctx) → Response  │
              └────────────┬─────────────┘
                           ▼
              ┌──────────────────────────┐
              │   Backend instance       │
              │  WebLLM / Transformers / │
              │  Native (unchanged)      │
              └──────────────────────────┘
```

### 4.1 Three tenets

1. **Single init path.** Host app calls `new DVAI(config).initialize()`. No separate server lifecycle step. Default `transport: "auto"` resolves at runtime: MSW in browser, HTTP in Node, `"none"` in Web/Service Worker contexts.
2. **Handlers never see HTTP framework types.** Each handler is `async (body: any, ctx: HandlerContext) => Response`. They consume already-parsed JSON and return a web-standard `Response`. Streaming responses are `new Response(readableStream, { headers: sseHeaders })` — both MSW and `http.createServer` can emit this shape.
3. **Transports are thin adapters.** MSW transport registers routes with `msw/browser` and delegates to handlers. HTTP transport runs `http.createServer`, parses JSON bodies, routes by path, delegates to handlers, streams responses. Neither transport contains business logic.

### 4.2 Module layout (single package)

Everything lives inside `@dvai-bridge/core`. `transports/http.ts` uses `await import("node:http")` inside a function body so browser bundlers never statically see the Node import. `transports/msw.ts` statically imports `msw/browser`. No new package, no peer-dep dance.

```
packages/dvai-bridge-core/src/
├── handlers/
│   ├── index.ts          # barrel re-exports
│   ├── context.ts        # HandlerContext + BackendInterface types
│   ├── chat.ts           # handleChatCompletion
│   ├── completions.ts    # handleCompletion + legacy helpers
│   ├── embeddings.ts     # handleEmbeddings
│   └── models.ts         # handleModels
├── transports/
│   ├── index.ts          # barrel + selectTransport()
│   ├── types.ts          # Transport interface, TransportStartResult
│   ├── msw.ts            # MswTransport (static msw/browser import)
│   ├── http.ts           # HttpTransport (dynamic node:http import)
│   └── port-fallback.ts  # tryBind() + BASE_PORT const
└── index.ts              # DVAI class, thinner, orchestrates transport selection
```

## 5. Repository restructure (included in Phase 0)

### 5.1 New layout

```
dvai-edge/
├── packages/                     # published npm packages ONLY
│   ├── dvai-bridge-core/
│   ├── dvai-bridge-react/
│   └── dvai-bridge-vanilla/
├── examples/                     # NEW — root-level, never published
│   ├── README.md                 # index of examples, one-line each
│   ├── web-react/                # ← moved from packages/dvai-bridge-core/example/test-app
│   └── node-langchain/           # ← promoted from the standalone .js file
├── docs/
├── scripts/
├── pnpm-workspace.yaml
└── package.json
```

### 5.2 Five concrete changes

1. **Move** `packages/dvai-bridge-core/example/test-app` → `examples/web-react`.
2. **Promote** the loose `example/langchain-node-example.js` into a proper `examples/node-langchain/` with `package.json` + `README.md`. Delete the standalone `.js`. Rewrite the example to use the new HTTP transport + `dvai.baseUrl` (making it actually runnable for the first time; previously broken in Node because MSW can't register without `navigator.serviceWorker`).
3. **Update** `pnpm-workspace.yaml` — swap `packages/dvai-bridge-core/example/*` for `examples/*`.
4. **Add `files` field** to all three package `package.json`s:
   ```json
   "files": ["dist", "bin", "README.md", "LICENSE"]
   ```
   Belt-and-braces allowlist. Even if `example/` folders return inside a package dir later, they can't ship to npm.
5. **Add** `examples/README.md` — a table indexing each example by platform / backend / use case. This becomes the landing spot for all future-phase examples.

### 5.3 Sequencing

Do the restructure **first**, as the initial unit of work under Phase 0. Reasons: isolated, reviewable independently, the `files` allowlist prevents accidental ship of the upcoming transport code, and the restructure doesn't touch `src/` so it doesn't conflict with the handler extraction.

## 6. Handler module

### 6.1 BackendInterface (tight typing)

All three existing backends (`WebLLMBackend`, `TransformersBackend`, `NativeBackend`) already satisfy this structurally — no backend changes required. Future native backends (CoreML, MediaPipe LLM, ONNX GenAI, Foundation Models, etc.) conform to the same interface.

```ts
export interface BackendInterface {
  chatCompletion(body: any): Promise<any>;
  createStreamingResponse(body: any): ReadableStream<Uint8Array>;
  embedding?(inputs: string | string[]): Promise<number[][]>;
  /** WebLLM sets this on fatal errors; triggers recovery path. */
  lastFatalError?: unknown;
  clearFatalError?(): void;
}
```

### 6.2 HandlerContext

```ts
export interface HandlerContext {
  /** Active backend; null means "not initialized" → 503. */
  backend: BackendInterface | null;

  /**
   * Resolved backend kind. Used only for error messages and the model
   * echo in responses. Union widens as new backends are added in later
   * phases — handlers must not dispatch on this value; always duck-type
   * on backend methods instead.
   */
  resolvedBackend: "webllm" | "transformers" | "native";

  /** Model identifier echoed back in responses. */
  modelId: string;

  /**
   * Optional recovery hook. Handler calls this before a retry when
   * backend.lastFatalError is set. DVAI owns the retry counter and
   * throws when exhausted; handler only awaits. Undefined → no recovery.
   */
  onRecovery?: () => Promise<void>;
}
```

### 6.3 Handler signatures

```ts
handleChatCompletion(body: any, ctx: HandlerContext): Promise<Response>
handleCompletion(body: any, ctx: HandlerContext):     Promise<Response>
handleEmbeddings(body: any, ctx: HandlerContext):     Promise<Response>
handleModels(ctx: HandlerContext):                    Promise<Response>
```

Return is always a web-standard `Response`. Streaming uses `new Response(readableStream, { headers: sseHeaders })`. `Response.json(obj)` replaces `HttpResponse.json(obj)`; MSW dependency is dropped from the handler module entirely.

### 6.4 Extraction mechanics

Minimum-diff extraction of the four arrow functions currently inside `DVAI.buildMswHandlers`:

1. Lift each arrow function to a top-level `async function handleX(body, ctx) { ... }`.
2. Replace every `self.backendInstance` → `ctx.backend`, `self.resolvedBackend` → `ctx.resolvedBackend`, etc.
3. Replace `HttpResponse.json(x)` → `Response.json(x)`.
4. Replace the inline recovery block with `await ctx.onRecovery?.()`.
5. `DVAI.buildMswHandlers()` shrinks to ~20 lines that wrap each handler in `msw.http.post(url, async ({request}) => handleX(await request.json(), this.getHandlerContext()))`.

New private method:

```ts
private getHandlerContext(onProgress: (info: any) => void): HandlerContext {
  return {
    backend: this.backendInstance,
    resolvedBackend: this.resolvedBackend,
    modelId:
      this.resolvedBackend === "transformers" ? this.transformersModelId :
      this.resolvedBackend === "native"       ? this.nativeModelPath :
                                                this.modelId,
    onRecovery: this.resolvedBackend === "webllm"
      ? () => this.attemptRecovery(onProgress)
      : undefined,
  };
}
```

Built once per `initialize()`, passed to the transport. Since it captures `this`, state updates on `DVAI` (e.g., `backendInstance` replaced during recovery) are visible through the same `ctx` reference.

### 6.5 Legacy helpers

`chatToLegacyCompletion` and `legacyCompletionStreamAdapter` move into `handlers/completions.ts` and are re-exported from `src/index.ts` unchanged — existing tests import them from the public entry.

### 6.6 Error responses (preserve current behavior)

| Condition | Status | Body |
|---|---|---|
| `backend == null` | 503 | `{ error: "AI engine not initialized" }` |
| Embeddings on WebLLM | 400 | `{ error: "...Use backend: 'transformers' or 'native'..." }` |
| Missing `input` on embeddings | 400 | `{ error: "Missing 'input' field." }` |
| Thrown exception | 500 | `{ error: error.message }` |

No alignment to OpenAI's nested error shape in Phase 0. Equivalence test asserts same status + same body.

## 7. Transport layer

### 7.1 Transport interface

```ts
export interface Transport {
  readonly kind: "msw" | "http" | "none";
  start(ctx: HandlerContext): Promise<TransportStartResult>;
  stop(): Promise<void>;
}

export interface TransportStartResult {
  /** The URL the host app points its OpenAI SDK at (no trailing slash). */
  baseUrl: string;
  /** Populated only for http; undefined for msw/none. */
  port?: number;
}
```

### 7.2 Selection logic

```ts
function selectTransport(config): "msw" | "http" | "none" {
  // Explicit "" serviceWorkerUrl disables transport (backward-compat escape hatch)
  if (config.serviceWorkerUrl === "" && config.transport == null) return "none";
  if (config.transport !== "auto" && config.transport != null) return config.transport;
  if (isBrowserLike()) return "msw";
  if (isNode()) return "http";
  return "none";
}

function isBrowserLike() {
  return typeof window !== "undefined"
      && typeof document !== "undefined"
      && typeof navigator !== "undefined"
      && typeof navigator.serviceWorker !== "undefined";
}
function isNode() {
  return typeof process !== "undefined"
      && process.versions != null
      && process.versions.node != null;
}
```

Matrix:

| Context | Resolved |
|---|---|
| Browser main thread | `msw` |
| Web Worker | `none` (informational log) |
| Service Worker | `none` |
| Electron renderer | `msw` |
| Electron main process | `http` |
| Plain Node | `http` |

Worker-context log:
```
[DVAI] Running in a Web Worker — no transport started.
       Use dvai.chatCompletion() directly, or register MSW on the main thread.
```

### 7.3 MswTransport

Near-identical to today's MSW wiring, lifted out of `DVAI`. `start()` calls `setupWorker(...routes).start({ onUnhandledRequest: "bypass", serviceWorker: { url: this.config.serviceWorkerUrl } })`. Route URLs computed from `mockUrl` exactly as today (preserves all existing consumers). `baseUrl` = `mockUrl` with `/chat/completions` stripped. `port` = undefined.

### 7.4 HttpTransport

```ts
async start(ctx: HandlerContext): Promise<TransportStartResult> {
  const { createServer } = await import("node:http");
  const server = createServer(async (req, res) => {
    try { await route(req, res, ctx, this.config); }
    catch (err) { writeJson(res, 500, { error: (err as Error).message }, corsHeaders); }
  });
  const port = await tryBind(server, this.config.httpBasePort, this.config.httpMaxPortAttempts);
  this.server = server;
  return { baseUrl: `http://127.0.0.1:${port}/v1`, port };
}
```

#### Route table (fixed, not configurable)

| Method | Path | Handler |
|---|---|---|
| `POST` | `/v1/chat/completions` | `handleChatCompletion` |
| `POST` | `/v1/completions` | `handleCompletion` |
| `POST` | `/v1/embeddings` | `handleEmbeddings` |
| `GET` | `/v1/models` | `handleModels` |
| `OPTIONS` | `*` | CORS/PNA preflight → 204 |
| any | unknown | 404 `{ error: "not found" }` |

#### Body parsing & response writing

- `req` → buffer body → `JSON.parse` → pass to handler.
- Handler returns web-standard `Response`.
- If `response.body` is a `ReadableStream`: iterate with `getReader()` and `res.write(chunk)` until done; set SSE headers from the `Response`.
- Otherwise: `response.text()` → `res.end(text)` with status + headers copied from the `Response`.

The `Response` → Node `ServerResponse` adapter lives in `transports/http.ts`, ~30 lines, no external deps.

#### CORS + PNA headers (every response)

```
Access-Control-Allow-Origin: *                  (configurable via corsOrigin)
Access-Control-Allow-Methods: POST, GET, OPTIONS
Access-Control-Allow-Headers: Content-Type, Authorization
Access-Control-Allow-Private-Network: true
```

`OPTIONS` returns `204` with these headers and no body. This is required for Chrome/Edge Private Network Access: HTTPS pages calling loopback servers require this header or requests are blocked.

### 7.5 Port-fallback helper

```ts
export const BASE_PORT = 38883;
export const MAX_PORT_ATTEMPTS = 16;

export async function tryBind(
  server: Server,
  basePort = BASE_PORT,
  maxAttempts = MAX_PORT_ATTEMPTS,
  host = "127.0.0.1",
): Promise<number> {
  for (let i = 0; i < maxAttempts; i++) {
    const port = basePort + i;
    try {
      await new Promise<void>((resolve, reject) => {
        server.once("error", reject);
        server.listen(port, host, () => { server.off("error", reject); resolve(); });
      });
      return port;
    } catch (err: any) {
      if (err.code !== "EADDRINUSE") throw err;
    }
  }
  throw new Error(
    `[DVAI] Could not bind HTTP transport to any port in range ` +
    `${basePort}..${basePort + maxAttempts - 1} (all in use). ` +
    `Another local AI server may already be running.`,
  );
}
```

`BASE_PORT` and `MAX_PORT_ATTEMPTS` are exported so host apps and docs can reference them.

### 7.6 HTTPS / loopback decision

**Plain HTTP on 127.0.0.1. No HTTPS.**

Rationale: public CAs will not issue certs for `127.0.0.1` or `localhost`. Self-signed certs fail iOS ATS and Android NSC by default; accepting them requires host-app opt-out of cert validation, which is *worse* security-wise than allowing cleartext-to-loopback. Real certs for a public domain that DNS-resolves to 127.0.0.1 (Plex-style `*.plex.direct`) ship a private key in every app (extractable, revocable, expiring). All mainstream hybrid frameworks (Capacitor, Cordova, Ionic, Expo, React Native dev server) go plain HTTP on loopback.

**Android cleartext-to-loopback** will be handled by auto-injection of a `network-security-config.xml` via the Capacitor plugin (Phase 1) and Android AAR (Phase 3) Gradle scripts. Developer never touches the config manually. Not a Phase 0 concern.

### 7.7 `mockUrl` under HTTP

Ignored. One-time console warning on `initialize()` if the user set it explicitly:

```
[DVAI] mockUrl config is ignored under transport="http".
       The HTTP server always serves at /v1/*. Use dvai.baseUrl
       to get the exact endpoint (currently: http://127.0.0.1:38883/v1).
```

## 8. Public API on DVAI

### 8.1 Config additions

```ts
export interface DVAIConfig {
  // ...existing fields unchanged...

  /**
   * Which transport to use for the OpenAI-compatible surface.
   * - "auto"  (default) → msw in browser, http in Node, none in workers
   * - "msw"  → force MSW (browser only; errors elsewhere)
   * - "http" → force HTTP server (Node only; errors elsewhere)
   * - "none" → no transport; use dvai.chatCompletion() directly
   */
  transport?: "auto" | "msw" | "http" | "none";

  /** HTTP-only. Base port. Default: 38883. */
  httpBasePort?: number;

  /** HTTP-only. Max port-fallback attempts. Default: 16. */
  httpMaxPortAttempts?: number;

  /**
   * HTTP-only. Controls the Access-Control-Allow-Origin response header.
   * - "*"               → echo "*" (default; dev-friendly)
   * - "https://x.com"   → echo that exact origin
   * - ["a.com","b.com"] → match the request's Origin header against the
   *                        list; echo the matched value. Requests from
   *                        unlisted origins get ACAO omitted (browser blocks).
   */
  corsOrigin?: string | string[];
}
```

Deliberately **not** added:
- `httpHost` — hardcoded to `127.0.0.1` (no footgun for binding to `0.0.0.0`).
- `autoStartTransport` — `autoInit` already covers start-on-construction.

### 8.2 New public fields

```ts
class DVAI {
  // ...existing fields unchanged...
  public baseUrl?: string;
  public port?: number;
}
```

Set during `initialize()` after `transport.start(ctx)`. Plain fields, matching the existing `mockUrl: string` style.

### 8.3 New methods (symmetric with getActiveBackend())

```ts
getBaseUrl(): string | undefined
getPort(): number | undefined
getActiveTransport(): "msw" | "http" | "none"
```

Method-style enables callback passing (`obj.on("ready", dvai.getBaseUrl.bind(dvai))`). Fields and methods coexist — same values, two access patterns.

### 8.4 Updated `initialize()` flow

```
1. resolveBackend()              (unchanged)
2. validator.validate()          (unchanged)
3. initializeBackend()           (unchanged)
4. resolveTransport()            NEW: "auto" → msw/http/none
5. transport = create()          NEW: lazy import + construct
6. ctx = getHandlerContext()     NEW
7. { baseUrl, port } =
     await transport.start(ctx)  NEW
8. this.baseUrl = baseUrl
   this.port    = port
9. this.isReady = true
```

Backend comes up **before** transport. Server isn't listening until backend is ready — no race where an early request hits a null backend.

### 8.5 Updated `unload()`

```
1. await backendInstance.unload()  (unchanged)
2. await transport.stop()          NEW (replaces worker.stop())
3. clear baseUrl, port, isReady
```

### 8.6 Migration impact

| Consumer | Old behavior | New behavior | Action? |
|---|---|---|---|
| Browser (React/Vanilla) | MSW registered automatically | Same (via `transport: "auto"` → `msw`) | None |
| Node | MSW setup would crash (no `navigator.serviceWorker`) | HTTP server bound at 38883 | None — now works |
| Web Worker | MSW skipped (implicit) | Transport = `none` + informational log | None |
| `serviceWorkerUrl: ""` set | MSW skipped | Transport = `none` | None — preserved |
| Custom `mockUrl` | Used by MSW | Used by MSW; ignored under HTTP with warning | None for MSW; note warning under HTTP |

Zero breaking changes for existing browser consumers.

### 8.7 `serviceWorkerUrl: ""` backward-compat escape hatch

**Preserved.** If `serviceWorkerUrl === ""` and `transport` is unset, resolution short-circuits to `"none"`. Documented in the config reference. Unit-tested in `transport.test.ts`.

If `transport: "msw"` is set **explicitly** alongside `serviceWorkerUrl: ""`, the explicit transport wins and a console warning fires:
```
[DVAI] serviceWorkerUrl is empty but transport='msw' was requested; MSW will fail to register.
```

## 9. Testing strategy

### 9.1 Handler unit tests — `handlers.test.ts`

One file, ~20 cases covering all four handlers with fabricated `HandlerContext` and stub backends. Cases include: happy path for each handler, `backend: null` (503), streaming path for chat + legacy completions, recovery-after-fatal-error path (mock `onRecovery`), embeddings-on-webllm (400), missing-input embeddings (400), exception → 500, legacy conversion shape, legacy streaming adapter SSE framing.

Test env: default `node`. Pure function tests.

### 9.2 Port-fallback tests — `port-fallback.test.ts`

Unit tests for `tryBind`:
- Binds base port when free.
- Retries +1 on `EADDRINUSE`, returns first free port.
- Throws with actionable message listing the tried range after max attempts.
- Re-throws non-`EADDRINUSE` errors (e.g., `EACCES`) without retry.

Uses a deliberately non-default port range (e.g., 39001+) to avoid colliding with a dev-running DVAI.

### 9.3 Equivalence test — `transport-equivalence.test.ts` (THE Phase-0 deliverable)

One deterministic `MockBackend` fixture; two transports fed the same request; assert identical status + body. Covers:
- `POST /v1/chat/completions` (non-streaming)
- `POST /v1/chat/completions` (streaming — collected SSE lines, modulo timing)
- `POST /v1/completions` (legacy non-streaming)
- `POST /v1/embeddings` against `MockEmbeddingBackend`
- `GET /v1/models`
- Error paths: `backend: null` (503), unknown route under HTTP (404).

Primary approach: single file with `// @vitest-environment happy-dom` for the MSW side, using `undici` / Node built-in `fetch` for the HTTP side against `http://127.0.0.1:<testPort>/v1/...`.

Fallback if per-test env proves awkward: split into `transport-equivalence.msw.test.ts` (`happy-dom` env) and `transport-equivalence.http.test.ts` (node env), sharing a `fixtures.ts` with the canonical request/response pairs.

### 9.4 Not tested in Phase 0

- End-to-end against real backends (covered by existing `blank-detection.test.ts`, `transformers-backend.test.ts`).
- Real-browser CORS/PNA enforcement (captured for Phase 1 with real devices).
- Electron integration (Phase 2).

### 9.5 CI impact

Net-zero. `happy-dom` added as dev dep (likely already transitively via MSW tooling). ~35 new test cases, all sub-second.

## 10. Operational rollout

### 10.1 Version bump

`1.5.2` → `1.6.0` (minor). All additive; no breaking changes. Bump the root `package.json`; `scripts/sync-versions.js` propagates to `packages/*` at `prebuild`.

### 10.2 Changelog

Create `CHANGELOG.md` at repo root following Keep a Changelog conventions. Draft entry for 1.6.0:

```markdown
# Changelog

All notable changes to this project are documented here.

## [1.6.0] — 2026-MM-DD

### Added
- `transport` config option: `"auto" | "msw" | "http" | "none"`.
- HTTP transport for Node and Electron main process (base port 38883,
  +1 fallback up to 16 attempts on EADDRINUSE).
- `dvai.baseUrl` / `dvai.port` fields.
- `dvai.getBaseUrl()` / `dvai.getPort()` / `dvai.getActiveTransport()` methods.
- New transport-agnostic handler module under `src/handlers/`.
- CORS + Private Network Access headers on HTTP transport responses
  (enables HTTPS pages calling loopback).
- `BASE_PORT` and `MAX_PORT_ATTEMPTS` exported constants.
- `httpBasePort`, `httpMaxPortAttempts`, `corsOrigin` config options.
- Root-level `examples/` directory (moved out of the package dir).
- `files` allowlist on all package.json files.

### Changed
- `mockUrl` is now MSW-specific. Under HTTP transport, it is ignored
  with a one-time console warning. Read `dvai.baseUrl` for the real URL.
- `DVAI` in Node now auto-starts a real HTTP server (previously
  crashed trying to register MSW without `navigator.serviceWorker`).
- Internal `buildMswHandlers` refactored into pure handler functions
  + thin MSW transport adapter.

### Removed
- `packages/dvai-bridge-core/example/langchain-node-example.js`
  replaced by the runnable `examples/node-langchain/` project.

### Fixed
- `new DVAI()` in plain Node no longer crashes.

### Migration guide: 1.5.x → 1.6.0

**Browser consumers:** no action. `new DVAI({})` continues to use MSW
with identical behavior.

**Node / Electron consumers:** `DVAI` now auto-boots an HTTP server at
`http://127.0.0.1:38883/v1`. Read `dvai.baseUrl` and pass it to your
OpenAI SDK. If you want the old direct-inference-only behavior, pass
`transport: "none"` or `serviceWorkerUrl: ""`.

**Custom `mockUrl` + HTTP:** `mockUrl` is ignored under HTTP transport.
If you need a specific URL shape, either stay on MSW (`transport: "msw"`,
browser only) or read `dvai.baseUrl` at runtime.
```

GitHub Release notes mirror this content.

### 10.3 Docs updates

New VitePress pages/sections:

| File | Change |
|---|---|
| `docs/guide/transports.md` | **NEW** — MSW vs HTTP, when each is used, port semantics |
| `docs/guide/getting-started.md` | Add Node quick-start snippet |
| `docs/guide/introduction.md` | Mention transport auto-detection in "Key backends" |
| `docs/reference/api.md` | Document `transport`, `httpBasePort`, `httpMaxPortAttempts`, `corsOrigin`, `baseUrl`, `port`, `getBaseUrl()`, `getPort()`, `getActiveTransport()` |
| `docs/migration/v1.5-to-v1.6.md` | **NEW** — migration guide from changelog |
| `README.md` (root) | Add "Node / Electron Usage" section; update config reference table; add `baseUrl`/`port` to the "Key Features" list |

### 10.4 Release process (per the user's existing workflow)

1. Merge Phase 0 branch to `main` after spec + plan + code all green.
2. Bump root `package.json` version `1.5.2` → `1.6.0`.
3. Finalize `CHANGELOG.md` entry with the real release date.
4. Create a git tag of the form `v1.6.0` (matches the `v*` pattern in `publish.yml`).
5. The existing GitHub Actions workflow publishes to GitHub Packages. **Note:** `publish.yml` is currently on `workflow_dispatch` only. If auto-publish on tag is desired, uncomment the `on.push.tags` trigger — this is a separate ops confirmation.

## 11. Open questions / confirmation items

1. **`publish.yml` auto-trigger.** Currently manual-only. Enable the tag trigger as part of 1.6.0 or keep manual-dispatch? (Not a Phase 0 blocker; recorded for rollout.)
2. **VitePress site regeneration.** `pnpm --filter docs build` — verify in CI or manual? (Capture in rollout checklist.)

## 12. Deliverable summary

A single PR (or a stack of small PRs under one branch) containing:

1. Repo restructure: `examples/` at root, `files` allowlist on all packages, workspace config update.
2. New `src/handlers/` module: pure handler functions + `HandlerContext` + `BackendInterface`.
3. New `src/transports/` module: MSW + HTTP transports + port-fallback helper.
4. `DVAI` class updates: `transport` config, env detection, `baseUrl`/`port` fields and methods, `getActiveTransport()`.
5. Tests: handler units + port-fallback units + transport-equivalence integration.
6. Docs: new transport guide, API reference updates, migration guide, README updates.
7. Version bump `1.5.2` → `1.6.0` + `CHANGELOG.md`.

All existing tests continue to pass. No existing public API removed. No backend behavior modified.
