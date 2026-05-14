# API Reference

Detailed reference for the `DVAI` configuration and common types.

## `DVAIConfig`

The main configuration object used to initialize the orchestration layer.

| Property                | Type                                               | Default                                          | Description                                                                                                                                              |
| :---------------------- | :------------------------------------------------- | :----------------------------------------------- | :------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `backend`               | `"webllm" \| "transformers" \| "native" \| "auto"` | `"webllm"`                                       | The inference engine to use. Use `"auto"` for intelligent environment selection.                                                                         |
| `modelId`               | `string`                                           | `"gemma-2-2b-it-q4f16_1-MLC"`                    | WebLLM specific model identifier.                                                                                                                        |
| `transformersModelId`   | `string`                                           | `"onnx-community/gemma-3n-E2B-it-ONNX"`          | HuggingFace model ID for Transformers.js.                                                                                                                |
| `pipelineTask`          | `string`                                           | `"text-generation"`                              | Pipeline task for Transformers.js (e.g., `"text-generation"`, `"feature-extraction"`, `"image-text-to-text"`).                                           |
| `device`                | `"webgpu" \| "cpu" \| "auto"`                      | `"auto"`                                         | Device for Transformers.js inference. `"auto"` detects WebGPU availability.                                                                              |
| `dtype`                 | `string`                                           | —                                                | Quantization for Transformers.js models (e.g., `"q4"`, `"q4f16"`, `"q8"`, `"fp16"`).                                                                     |
| `transformersModelClass`      | `string`   | —                | Name of a transformers.js export to load via `ClassName.from_pretrained(modelId)`. Enables the [declarative multimodal loader](/guide/backends#declarative-multimodal-loader). Works in the worker AND on main-thread fallback. Leave unset to use the stock `pipeline()` factory. Example: `"Gemma4ForConditionalGeneration"`. |
| `transformersProcessorClass`  | `string`   | `"AutoProcessor"` | Processor class name for the declarative loader. Only used when `transformersModelClass` is set.                                                          |
| `transformersDisableEncoders` | `string[]` | `[]`             | Model submodule fields to null out after load (e.g. `["vision_encoder"]`). Purely declarative — the library nulls each named field if present; unknown/absent names are silently ignored. Host app controls this based on which modalities it actually uses. |
| `createPipeline`        | `CreatePipelineFn`                                 | —                                                | Custom pipeline factory for models whose processor call signature the declarative loader can't express. **Main-thread only** — function closures don't cross the Worker boundary. See [Custom Pipeline Factory](/guide/backends#custom-pipeline-factory-createpipeline). |
| `mockUrl`               | `string`                                           | `"https://api.openai.local/v1/chat/completions"` | The URL that MSW intercepts for OpenAI-compatible requests.                                                                                              |
| `serviceWorkerUrl`      | `string`                                           | `"/mockServiceWorker.js"`                        | Path to the MSW service worker script. Set to `""` to disable MSW.                                                                                       |
| `transformersWorkerUrl` | `string`                                           | `"/dvai-transformers.worker.js"`                 | Path to the Transformers.js inference worker. Set to `""` to run on main thread.                                                                         |
| `webllmWorkerUrl`       | `string`                                           | `"/dvai-webllm.worker.js"`                       | Path to the WebLLM inference worker.                                                                                                                     |
| `nativeModelPath`       | `string`                                           | —                                                | Path to the GGUF model file for the Native backend.                                                                                                      |
| `nativeGpuLayers`       | `number`                                           | `99`                                             | Number of layers to offload to GPU in Native backend.                                                                                                    |
| `nativeThreads`         | `number`                                           | `4`                                              | Number of CPU threads for Native inference.                                                                                                              |
| `nativeContextSize`     | `number`                                           | `2048`                                           | Context window size for Native backend.                                                                                                                  |
| `nativeEmbeddingMode`   | `boolean`                                          | `false`                                          | Initialize the native llama.cpp context in embedding mode. Required for `/v1/embeddings` on the native backend.                                          |
| `maxRetries`            | `number`                                           | `2`                                              | Number of automatic recovery attempts on fatal WebLLM errors.                                                                                            |
| `generationTimeout`     | `number`                                           | `60000`                                          | Maximum time (ms) allowed for generation before timing out.                                                                                              |
| `maxBlankChunks`        | `number`                                           | `20`                                             | Abort streaming after this many consecutive empty chunks.                                                                                                |
| `licenseKeyPath`        | `string`                                           | —                                                | Path or URL to a DVAI-Bridge license JWT. Auto-discovered from `dvai-license.jwt` at platform-conventional locations when unset. See [License setup](/guide/license/).                                                                |
| `licenseToken`          | `string`                                           | —                                                | Inline DVAI-Bridge license JWT (full token string). Highest-priority discovery path; wins over `licenseKeyPath` and env vars. Useful for serverless / CI deployments. See [License setup](/guide/license/).                          |
| `autoInit`              | `boolean`                                          | `true`                                           | Whether to initialize the backend immediately on mount (React only).                                                                                     |
| `transport`             | `"auto" \| "msw" \| "http" \| "none"`              | `"auto"`                                         | Transport selection. `"auto"` picks MSW in browser, HTTP in Node.                                                                                        |
| `httpBasePort`          | `number`                                           | `38883`                                          | HTTP transport base port (retries +1 up to 16 times).                                                                                                    |
| `httpMaxPortAttempts`   | `number`                                           | `16`                                             | Max HTTP port fallback attempts before throwing.                                                                                                         |
| `corsOrigin`            | `string \| string[]`                               | `"*"`                                            | HTTP `Access-Control-Allow-Origin` value or allowlist.                                                                                                   |
| `httpBindHost`          | `string \| undefined`                              | `"127.0.0.1"`                                    | **v3.1+.** Network interface to bind. Default loopback only — safe for single-device deployments. Set to `"0.0.0.0"` for LAN-target deployments (the v3.1 Hub, native SDKs running in target mode). Phone-as-source / single-device deployments should leave the default; a 0.0.0.0 bind without pairing protection exposes the OpenAI surface. |
| `offload`               | `OffloadConfig \| undefined`                       | `undefined`                                      | Phase 3 (v3.0+) — distributed-inference / device-offload config. See [`OffloadConfig`](#offloadconfig-v30) below + the [Distributed Inference guide](/guide/distributed-inference). When unset, the library behaves exactly as v2.x. |
| `chatCompletionInterceptor` | `(body, ctx, headers?) => Promise<Response \| null> \| undefined` | `undefined` | **v3.1+.** First-chance hook for `/v1/chat/completions`. Return a `Response` to short-circuit; return `null` to fall through to the default local-backend handler. The Hub uses this to enforce its substitution policy + route through external engines. See [Chat completion interceptor](/guide/distributed-inference#chat-completion-interceptor-v31). |

---

## `OffloadConfig` (v3.0+)

Opts the library into peer-device discovery + offload. v2.x consumer
code that doesn't set `offload` keeps working unchanged.

| Property | Type | Default | Description |
| --- | --- | --- | --- |
| `enabled` | `boolean` | `false` | Master switch. Opt-in at v3.0; nothing changes when off. |
| `discoverLAN` | `boolean` | `true` | Run mDNS / DNS-SD to discover peers on the local network. Browsers skip (can't speak mDNS); native SDKs use the platform-native API. |
| `minLocalCapability` | `number` | `10` | Estimated decode tok/s the local device must hit to run locally. Below this, the library looks for a peer. |
| `rendezvousUrl` | `string \| undefined` | `undefined` | URL of a self-hosted [rendezvous server](/guide/self-hosting-rendezvous). If unset, the internet path is disabled — only LAN works. |
| `knownPeers` | `Peer[] \| undefined` | `undefined` | Pre-known peers (skip discovery). Useful for corporate device registries or persisted pairings. |
| `onPairingRequest` | `(peer: Peer) => Promise<boolean \| { approved: true; pairingKey: string } \| { approved: false }>` | denies | Hook to surface a "Allow this device to pair?" UI to the user. Default: deny. **v3.1+:** the return type was widened to a tagged union — return `{ approved: true, pairingKey }` when your host app maintains its own pairing state (e.g. the Hub's `MultiTenantPairing`) and wants the library to use that key instead of generating a fresh one. v3.0 `boolean` returns continue to work. |
| `onOffload` | `(peer: Peer) => void` | no-op | Diagnostic callback when a request is offloaded. Useful for analytics + UI feedback. |
| `customDiscovery` | `() => Promise<Peer[]>` | `undefined` | Optional plug-in for app-specific discovery (e.g. corporate device registry). Combined with mDNS + `knownPeers`. |

### Per-request override (`X-DVAI-Offload` header)

| Header value | Meaning |
| --- | --- |
| `prefer` (default) | Offload if local can't serve fast enough AND a faster peer exists. |
| `never` | Always run locally, even if slow. Privacy-sensitive prompts; on-device-only requirements. |
| `require` | Refuse rather than fall back. Returns the structured `no_capable_device` error if no qualified peer is reachable. |

### `Peer` type

| Property | Type | Description |
| --- | --- | --- |
| `deviceId` | `string` | Stable per-install peer device ID. |
| `deviceName` | `string` | Human-readable hint (iOS device name, hostname). |
| `dvaiVersion` | `string` | Library SemVer the peer is running. |
| `baseUrl` | `string` | OpenAI-compatible base URL the peer's local server exposes. |
| `appId` | `string \| undefined` | **v3.1+.** Identifies which application on the peer device is making the request — used by multi-tenant targets (Hub) to isolate per-app state. Optional for v3.0 SDK back-compat (Hub falls back to `deviceId`). |
| `loadedModels` | `string[]` | Models the peer claims to have loaded. |
| `capability` | `Record<string, number>` | Peer-reported `{modelId → tok/s}` map (advisory; verified before first use). |
| `via` | `"mdns" \| "static" \| "rendezvous" \| "custom"` | Discovery source. |
| `secure` | `boolean` | Whether the peer's URL uses TLS. |
| `lastSeenAt` | `number` | Unix ms — discovery sources update this. |

### `no_capable_device` error response

When the offload decision fails to find a qualified peer, the response
is OpenAI-error-shaped (HTTP 503 + `Retry-After: 30`):

```json
{
  "error": {
    "type": "no_capable_device",
    "code": 503,
    "message": "No device with capability ≥ 10 tok/s for model … was reachable.",
    "checked": [
      { "deviceId": "self", "capabilityScore": 4.2, "reason": "below threshold" }
    ],
    "localCapability": 4.2,
    "requiredAtLeast": 10,
    "rendezvousConfigured": true,
    "pairedRemotePeers": 0,
    "requestId": "..."
  }
}
```

### New `DVAI` instance methods (v3.0+)

| Method | Returns | Description |
| --- | --- | --- |
| `dvai.probeCapability()` | `Promise<CapabilityScore \| undefined>` | Run a 50-token cold-run against the active backend; persist the score per `(modelId, libraryVersion)`. No-op if `offload.enabled` is false. |
| `dvai.getCapability(modelId?)` | `Promise<CapabilityScore \| undefined>` | Return the cached probe score or a heuristic fallback. No-op if `offload.enabled` is false. |
| `dvai.getPeers()` | `Peer[]` | Snapshot of currently-discovered peers. |

See the [Distributed Inference guide](/guide/distributed-inference) for
the full design + flows.

---

## `CreatePipelineFn`

A factory function for custom model loading. Receives the dynamically-imported `@huggingface/transformers` module and a context object. Must return a `PipelineCallable`.

```typescript
type CreatePipelineFn = (
	transformers: any,
	ctx: {
		modelId: string;
		device: "webgpu" | "wasm";
		dtype?: string;
		onProgress?: (info: any) => void;
	},
) => Promise<PipelineCallable>;
```

## `PipelineCallable`

The function returned by `createPipeline`. Accepts chat messages and generation options, returns results matching the Transformers.js pipeline output format.

```typescript
type PipelineCallable = (messages: any, options?: any) => Promise<any>;
// Expected return shape: [{ generated_text: string }]
```

---

## `ChatOptions`

Options passed to `chatCompletion` or `createStreamingResponse`.

| Property      | Type            | Description                                                              |
| :------------ | :-------------- | :----------------------------------------------------------------------- |
| `messages`    | `ChatMessage[]` | Array of `{ role: "user" \| "assistant" \| "system", content: string }`. |
| `stream`      | `boolean`       | Whether to stream the response.                                          |
| `max_tokens`  | `number`        | Maximum number of tokens to generate.                                    |
| `temperature` | `number`        | Sampling temperature (usually 0 to 1).                                   |
| `top_p`       | `number`        | Nucleus sampling threshold.                                              |

---

## `DVAIInstance` (Core Class)

Methods available on the `DVAI` class instance.

### `initialize(onProgress?)`

Initializes the selected backend, starts workers, registers MSW handlers, and begins model downloading/loading. Accepts an optional progress callback.

### `chatCompletion(options)`

Returns a standard OpenAI-format response object. Works for both standard pipeline models and custom `createPipeline` models.

### `createStreamingResponse(options)`

Returns a `ReadableStream` that yields OpenAI-format SSE chunks. On the Transformers.js backend, streaming is real token-level streaming via `TextStreamer` (not word-by-word simulation).

### `embedding(inputs)`

Returns an array of embedding vectors (`number[][]`) for the given string or array of strings.

- `backend: "transformers"` requires `pipelineTask: "feature-extraction"`.
- `backend: "native"` requires `nativeEmbeddingMode: true`.
- Throws when called on the WebLLM backend.

### `runPipeline(inputs, options?)`

Runs the underlying Transformers.js pipeline directly with arbitrary inputs. Use for non-chat tasks (image generation, ASR, etc.).

### `unload()`

Completely unloads the engine and frees memory/workers.

### `getActiveBackend()`

Returns the currently resolved backend instance.

### Instance fields

- `dvai.baseUrl?: string` — URL to hand to OpenAI SDKs. `undefined` when `transport="none"`.
- `dvai.port?: number` — Bound HTTP port (HTTP transport only).

### Methods

- `dvai.getBaseUrl(): string | undefined` — Method form of `dvai.baseUrl`.
- `dvai.getPort(): number | undefined` — Method form of `dvai.port`.
- `dvai.getActiveTransport(): "msw" | "http" | "none"` — Resolved transport after `initialize()`.

---

## OpenAI-Compatible Endpoints

DVAI-Bridge registers MSW handlers for these endpoints, derived from `mockUrl` (defaults to `https://api.openai.local/v1/chat/completions`). If `mockUrl` ends with `/chat/completions`, the base URL is its parent; siblings are registered as:

| Method | Endpoint               | Notes                                                                                                                                                                                                                      |
| :----- | :--------------------- | :------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `POST` | `/v1/chat/completions` | Full chat API. Streaming supported on all backends.                                                                                                                                                                        |
| `POST` | `/v1/completions`      | Legacy OpenAI completion endpoint. The `prompt` field is wrapped into a single user message and forwarded to `/v1/chat/completions`; the response is rewritten to the legacy `text_completion` shape. Streaming supported. |
| `POST` | `/v1/embeddings`       | Returns embeddings. Gated on backend: `transformers` + `pipelineTask: "feature-extraction"`, or `native` + `nativeEmbeddingMode: true`. Returns `400` on WebLLM.                                                           |
| `GET`  | `/v1/models`           | Returns a single-entry list with the currently loaded model ID.                                                                                                                                                            |

### Distributed-inference plane (`/v1/dvai/*`, v3.0+; v3.1 wire fixes)

Mounted only when `offload.enabled = true`. v3.0 had these handlers
defined but never dispatched; **v3.1 wires them into the HTTP
transport so they actually return JSON instead of 404**.

| Method | Endpoint | Notes |
| :--- | :--- | :--- |
| `GET`  | `/v1/dvai/health`     | Liveness, version, uptime, `currentModelId`. |
| `GET`  | `/v1/dvai/peers`      | Discovered LAN peers. |
| `GET`  | `/v1/dvai/capability` | Local capability cache (per-model tok/s). |
| `POST` | `/v1/dvai/probe`      | Run a fresh capability probe against the active backend. |
| `POST` | `/v1/dvai/handshake`  | LAN-pairing handshake. v3.1 request body adds optional `appId`; response now echoes `pairingKey` + `peerDeviceId` so the requester can HMAC-sign subsequent calls. |
| `POST` | `/v1/dvai/pair-qr`    | Rendezvous QR-pair (v3.0 — partial; per-SDK glue is a v3.1 finalization item). |
| `POST` | `/v1/dvai/pair-scan`  | Rendezvous QR-scan (same status). |

#### Handshake request shape (v3.1)

```jsonc
POST /v1/dvai/handshake
{
  "peerDeviceId": "phone-pixel-9",
  "peerDeviceName": "Pixel 9",
  "appId": "com.acme.chat",        // v3.1+ optional; falls back to peerDeviceId
  "via": "lan-handshake"
}
```

#### Handshake response shape (v3.1)

```jsonc
{
  "paired": true,
  "pairedAt": 1778184673778,
  "via": "lan-handshake",
  "pairingKey": "yxQwo0Xv9dws…",   // v3.1+ — base64url-encoded 256-bit HMAC secret
  "peerDeviceId": "phone-pixel-9"  // v3.1+ — echoed for confirmation
}
```

The pairing key is sent in the response over the same Wi-Fi the
handshake request crossed (LAN trust model). Rendezvous-QR pairings
use ECDH key agreement and don't reach this handler.

### Identity-signed `/v1/chat/completions` (v3.1)

Once paired, a peer can include four request headers to identify
itself in the audit log:

| Header | Description |
| --- | --- |
| `X-DVAI-Peer-Device-Id` | The peer's `deviceId` (matches the handshake). |
| `X-DVAI-App-Id` | The peer's `appId` (matches the handshake). |
| `X-DVAI-Nonce` | Per-request nonce (any unique string). |
| `X-DVAI-Signature` | Hex `HMAC-SHA256(pairingKey, composeSignedMessage(nonce, "POST", "/v1/chat/completions", bodyJson))`. |

The `composeSignedMessage` and `signHmac` / `verifyHmac` primitives
are exported from `@dvai-bridge/core`'s package root. Targets
(Hub) verify the signature against the stored pairing key:
- All four headers present + verifies → audit row records the real
  `appId` / `peerDeviceId`.
- All four absent → backwards-compat anonymous path (audit logs
  `appId: "anonymous"`). v3.0 SDKs that don't sign use this path.
- Partial set → 401 with reason "all four or none".

The Hub interceptor refuses requests whose model parses to
`family: "unknown"` (parser sentinel for unparseable model names) —
substituting on a sentinel-vs-sentinel match has no semantic basis.
