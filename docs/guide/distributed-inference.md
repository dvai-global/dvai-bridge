# Distributed inference (v3.0+)

A v3.0 dvai-bridge instance can offload its inference to another
dvai-bridge instance running on a stronger device when the local
device's hardware can't serve the model fast enough. Two paths:

1. **LAN**: zero setup. Devices on the same Wi-Fi auto-discover each
   other via mDNS / Bonjour and offload directly.
2. **Internet**: opt-in. If you self-host the
   [rendezvous server](./self-hosting-rendezvous.md) and configure its
   URL, devices on different networks pair via QR scan + the
   rendezvous server, then offload through the same encrypted relay.

The OpenAI HTTP wire surface stays unchanged. Your consumer code
points at `dvai.baseUrl` and writes plain OpenAI requests; the
library decides per-request whether to run locally or proxy to a peer.

This page is the consumer-facing config + behaviour. The
[API reference](/reference/api#offloadconfig-v30) lists every
`OffloadConfig` field with default values; the
[wire-protocol section](#wire-protocol-additions-in-v3-1) below
covers the v3.1 handshake + HMAC-signed identity headers; the
[v3.0 design rationale lives in `RESEARCH.md` §7](https://github.com/Westenets/dvai-bridge/blob/main/RESEARCH.md)
on the public repo.

## Quick start

Opt in by adding `offload` to your `DVAI` config (or to the equivalent
start-options on a native SDK):

```ts
import { DVAI } from "@dvai-bridge/core";

const dvai = new DVAI({
  backend: "auto",
  modelId: "Llama-3.2-3B-Instruct-Q4_K_M",
  offload: {
    enabled: true,
    discoverLAN: true,                        // mDNS — works without any server
    minLocalCapability: 10,                   // tok/s threshold; below this, look for a peer
    rendezvousUrl: "wss://rendezvous.myapp.com",  // optional; enables internet path
    onPairingRequest: async (peer) => {
      // Show your UI's "Allow Device A to use this device for AI?" prompt
      // and return the user's answer.
      return await myAppUiConfirm(peer.deviceName);
    },
    onOffload: (peer) => console.log(`offloaded to ${peer.deviceName}`),
  },
});

await dvai.initialize();

// Consumer code is unchanged from v2.x — point any OpenAI SDK at dvai.baseUrl.
const openai = new OpenAI({ baseURL: dvai.baseUrl, apiKey: "ignored" });
const r = await openai.chat.completions.create({
  model: "Llama-3.2-3B-Instruct-Q4_K_M",
  messages: [{ role: "user", content: "Hello!" }],
});
```

## OffloadConfig reference

| Field | Type | Default | Description |
| --- | --- | --- | --- |
| `enabled` | `boolean` | `false` | Master switch. Opt-in at v3.0; v2.x consumer code unchanged when off. |
| `discoverLAN` | `boolean` | `true` | Run mDNS / DNS-SD to find peers on the local network. Browsers skip (can't speak mDNS); native SDKs use platform-native mDNS. |
| `minLocalCapability` | `number` | `10` | Estimated decode tok/s the local device must hit to run locally. Below this, the library looks for a peer. |
| `rendezvousUrl` | `string \| undefined` | `undefined` | URL of a self-hosted [rendezvous server](./self-hosting-rendezvous.md). If unset, the internet path is disabled — only LAN works. |
| `knownPeers` | `Peer[] \| undefined` | `undefined` | Pre-known peers (skip discovery). Useful for corporate device registries or persisted pairings. |
| `onPairingRequest` | `(peer: Peer) => Promise<boolean>` | denies | Hook to surface a "Allow this device to pair?" UI to the user. Default: deny. The host app implements the UI. |
| `onOffload` | `(peer: Peer) => void` | no-op | Diagnostic callback when a request is offloaded. Useful for analytics + UI feedback. |
| `customDiscovery` | `() => Promise<Peer[]>` | `undefined` | Optional plug-in for app-specific discovery (e.g. corporate device registry). Combined with mDNS + `knownPeers`. |

## Per-request override (`X-DVAI-Offload` header)

Override the default offload policy on individual requests:

| Header value | Meaning |
| --- | --- |
| `prefer` (default) | Offload if local can't serve fast enough AND a faster peer exists. |
| `never` | Always run locally, even if slow. Useful for privacy-sensitive prompts the user wants to keep on-device. |
| `require` | Refuse rather than fall back. Returns the structured `no_capable_device` error if no qualified peer is reachable. |

```ts
// Force local — privacy-sensitive prompt
await openai.chat.completions.create(
  { model, messages },
  { headers: { "X-DVAI-Offload": "never" } },
);
```

## Capability assessment

The library decides "is this device fast enough?" by:

1. **Cold-run probe** on first use of a model: 50-token completion,
   measured tok/s, persisted per `(modelId, libraryVersion)`. Cache
   lives in IndexedDB (browser) / `~/.cache/dvai-bridge/` (Node) /
   `Application Support/dvai-bridge/` (iOS) / `cacheDir` (Android) /
   `LocalApplicationData` (.NET).
2. **Heuristic fallback** before the first probe: coarse score from
   detected NPU + RAM + GPU class. Conservative — under-promises so
   we offload more often than over-promise.

Trigger an explicit probe + persist with `await dvai.probeCapability()`
(no-op when `offload.enabled` is false). Check the cached score with
`await dvai.getCapability()`.

The numbers we care about are **tok/s decode rates** of the upstream
backend (llama.cpp, MediaPipe, MLX, etc.). They're properties of the
backend + model + device — not of dvai-bridge itself. See RESEARCH.md
§6.11 for why we don't publish first-party benchmarks.

## The "no capable device" error

When the offload decision returns `no_capable_device`, the response is
OpenAI-error-shaped:

```json
{
  "error": {
    "type": "no_capable_device",
    "code": 503,
    "message": "No device with capability ≥ 10 tok/s for model Llama-3.2-3B-Instruct-Q4_K_M was reachable.",
    "checked": [
      { "deviceId": "self", "capabilityScore": 4.2, "reason": "below threshold" },
      { "deviceId": "ABCD-1234", "deviceName": "Mac Studio M4 Max", "capabilityScore": 0, "reason": "discovered via mDNS but unreachable (timeout after 3s)" }
    ],
    "localCapability": 4.2,
    "requiredAtLeast": 10,
    "rendezvousConfigured": true,
    "pairedRemotePeers": 0,
    "requestId": "..."
  }
}
```

Returned with HTTP 503 + `Retry-After: 30`. Existing OpenAI clients
(LangChain, Vercel AI SDK, OpenAI's own SDKs) surface it as an error
naturally — no DVAI-specific error handler needed.

## QR-pairing flow (internet path)

When two devices are on different networks and need to pair:

1. **Source device** (the one that wants to offload) calls something
   like `dvai.startQrPairing()` (host-app SDK surface). The library
   opens a WebSocket to the rendezvous server and gets back a QR
   payload + a session ID.
2. **Source device** displays the QR payload as a QR code in its UI.
3. **Target device** scans the QR with its camera (host-app's UI).
4. **Target device** calls `dvai.completePairFromQrPayload(payload)`,
   which joins the rendezvous session and completes a fresh X25519
   key exchange.
5. The two devices now share a per-session secret. **The rendezvous
   server never sees plaintext** — it only relays public keys + AEAD-
   encrypted payloads.
6. From this point on, source's `dvai.baseUrl` requests can offload
   to target through the rendezvous relay.

Camera-side QR scanning is the host app's job (it's platform-specific:
AVFoundation on iOS, CameraX on Android, getUserMedia + a JS QR
decoder in browser). The library exposes the *generation* + *handshake*
APIs; the *scanning* surface is yours.

## LAN-pairing flow (no QR needed)

When two devices are on the same Wi-Fi:

1. mDNS discovers the peer automatically.
2. First time source A wants to offload to target B, A POSTs
   `/v1/dvai/handshake` to B with its identity + a nonce.
3. B's `onPairingRequest` callback fires with A's info; the user
   approves.
4. B generates a 256-bit pairing key and **echoes it back** in the
   handshake response (LAN trust model — same network the request
   crossed). Stored on both sides; the multi-tenant Hub stores it
   per-`(appId, peerDeviceId)`.
5. From this point on, A's offload requests carry four identity
   headers:
   - `X-DVAI-Peer-Device-Id`
   - `X-DVAI-App-Id`
   - `X-DVAI-Nonce`
   - `X-DVAI-Signature` — hex of
     `HMAC-SHA256(pairingKey, composeSignedMessage(nonce, method, path, bodyJson))`

   B verifies before serving. Verified requests log to the audit
   under the real `(appId, peerDeviceId)`; unsigned requests use the
   anonymous backwards-compat path (audit row keyed `"anonymous"`).
   Partial header sets are rejected with 401.
6. Pairings expire after `expireAfterDays` (default 30) of inactivity.
   Re-pair via fresh handshake.

### Wire-protocol additions in v3.1

| Field | Where | What |
| --- | --- | --- |
| `appId` | request body of `/v1/dvai/handshake` | Optional. Identifies which application on the peer device is pairing — the Hub uses it for multi-tenant isolation. v3.0 SDKs that don't send it pair under `peerDeviceId` as a fallback. |
| `pairingKey`, `peerDeviceId` | response body of `/v1/dvai/handshake` | New v3.1 echoes so the requester can store the shared key + confirm its identity. |
| `X-DVAI-*` headers | `/v1/chat/completions` | New per-request identity. Sign with `composeSignedMessage` + `signHmac` (re-exported from `@dvai-bridge/core` package root). |

### Chat-completion interceptor (v3.1)

`DVAIConfig.chatCompletionInterceptor` is a first-chance hook that
runs **before** the default `/v1/chat/completions` handler. The
v3.1 Hub uses it to apply substitution-policy + engine-bridge
routing without monkey-patching the transport. Return shape:

```ts
chatCompletionInterceptor?: (
  body: any,
  ctx: HandlerContext,
  headers?: Record<string, string>,
) => Promise<Response | null>;
```

- Return a `Response` → that's what the client gets.
- Return `null` → fall through to the default local-backend handler.

Headers are passed lower-cased so the interceptor can read v3.1
identity fields and verify HMAC against a stored pairing key.

## v3.2 — Per-SDK outgoing-offload routing

v3.0 shipped the wire protocol + decision logic in
`@dvai-bridge/core`; v3.1 packaged the strong-peer side as the
[DVAI Hub](./dvai-hub.md). v3.2 closes the loop by wiring the
**source side** in every native SDK so any consumer app — Android
Kotlin, iOS Swift, .NET, React Native, Flutter — gets
zero-code-change offload routing on every outgoing
`/v1/chat/completions` request.

### What changed for the consumer app

**Nothing.** That's the design point. You still call the same
`start()` you've always called and read `baseUrl` off the returned
`BoundServer`. v3.2's pre-routing proxy claims that public port and
decides per-request whether to serve the request locally or forward
to a paired peer. Your OpenAI client doesn't know the difference.

```kotlin
// Android — exact same code as v3.1, plus offload enabled.
val server = DVAIBridge.start(
    StartOptions(
        backend = BackendKind.Auto,
        modelPath = "/path/to/model.gguf",
        offload = OffloadConfig(
            enabled = true,
            minLocalCapability = 10.0,
            hardwareMinimum = 3.0,
        ),
    ),
)

// Use server.baseUrl with any OpenAI-compatible client.
// Internally, a Ktor pre-routing proxy decides per-request whether
// to forward locally or to a paired peer.
val client = OkHttpClient()
val req = Request.Builder()
    .url("${server.baseUrl}/v1/chat/completions")
    .post(jsonBody)
    .build()
client.newCall(req).execute()
```

### Pre-init hardware assessment (`assessHardware`)

Before any model download or backend init, consumer apps can ask
the SDK how this device is going to handle local inference:

```kotlin
val a = DVAIBridge.assessHardware(
    hardwareMinimum = 3.0,
    minLocalCapability = 10.0,
)
when (a.mode) {
    PrecheckMode.OK -> {
        // Run normally.
        DVAIBridge.start(opts)
    }
    PrecheckMode.OFFLOAD_ONLY -> {
        // Capable enough to bridge but not to run the model
        // comfortably. start() will skip the model load and
        // route every request to a paired peer.
        DVAIBridge.start(opts)
    }
    PrecheckMode.TOO_WEAK -> {
        // Below the hardware floor. Show your own UI explaining
        // the device isn't supported; don't call start().
        showCustomNotSupportedDialog(a.reason)
    }
}
```

Same shape on every SDK:

| Platform | Public method |
| --- | --- |
| TS / Node | `dvai.assessHardware({ hardwareMinimum, minLocalCapability })` |
| Android | `DVAIBridge.assessHardware(hardwareMinimum, minLocalCapability)` |
| iOS | `DVAIBridge.shared.assessHardware(hardwareMinimum:minLocalCapability:)` |
| .NET | `DVAIBridge.Shared.AssessHardware(hardwareMinimum, minLocalCapability)` |
| React Native | `DVAIBridge.assessHardware(hardwareMinimum, minLocalCapability)` |
| Flutter | `DVAIBridge.shared.assessHardware(hardwareMinimum: 3, minLocalCapability: 10)` |

Returns the same JSON-serializable shape on every platform:

```json
{
  "mode": "offload-only",
  "tokPerSec": 8.0,
  "reason": "estimated 8 tok/s, below the 10 tok/s comfort threshold — model will not be loaded locally; every request will be forwarded to a paired peer.",
  "hints": {
    "hasNpu": false,
    "ramGb": 8,
    "gpuClass": "integrated",
    "cpuClass": "mid"
  }
}
```

**The SDK never shows UI for hardware decisions** — the consumer
app decides what (if anything) to surface based on `mode`. That's a
deliberate v3.2 design point: SDK is a data source, not a UX driver.

### How the runtime decision works

Every chat-completion request through the SDK's public `baseUrl`
hits the pre-routing proxy first. The proxy:

1. Honours the `X-DVAI-Offload` header (`never` | `prefer` |
   `require`) — defaults to `prefer`.
2. Reads the live discovered-peer list (LAN mDNS + optional
   rendezvous).
3. Picks the best peer for the requested `model` (peers with the
   model already loaded preferred over higher-score peers without
   it).
4. If the best peer's score is at or above
   `OffloadConfig.minLocalCapability`, forwards the request with
   HMAC-signed identity headers (`X-DVAI-Peer-Device-Id`,
   `X-DVAI-App-Id`, `X-DVAI-Nonce`, `X-DVAI-Signature`).
5. Otherwise, serves the request locally (if a backend is loaded)
   or returns 503 `no_capable_device` (if not — i.e. offload-only
   mode).

In `offload-only` mode (precheck classified the device as too weak
to comfortably run the model), the SDK **never downloads or loads
the model file**. The proxy stands alone and forwards every
request. Saves bandwidth + battery on devices that wouldn't run
the model anyway.

### Per-platform implementation

Each native SDK uses the platform-idiomatic HTTP server in front of
its native backend:

| Platform | Proxy implementation |
| --- | --- |
| TS / Node | Built-in handler interceptor in `@dvai-bridge/core` |
| Android | Ktor 2.3 (CIO engine, +500 KB AAR) |
| iOS | Hummingbird 2.x (swift-nio backbone — also the local backend HTTP server as of v3.2.0; replaced Telegraph for proper SSE streaming) |
| .NET (desktop) | Kestrel middleware in the existing `OpenAIServer` |
| React Native | Delegates to native iOS / Android proxies |
| Flutter | Delegates to native iOS / Android proxies |

## Per-platform support matrix

| SDK | LAN discovery (mDNS) | Internet pairing (rendezvous) | Capability probe |
| --- | --- | --- | --- |
| Web (browser) | ❌ (browsers can't mDNS) | ✅ source-only (browser is offload source, not target) | ✅ via IndexedDB-cached probe |
| Web (Node) | ✅ via `multicast-dns` (optional dep) | ✅ | ✅ |
| iOS native | ✅ via `NWBrowser` / `NWListener` | ✅ | ✅ |
| Android native | ✅ via `NsdManager` | ✅ | ✅ |
| React Native | delegates to native | delegates to native | delegates to native |
| Flutter | delegates to native | delegates to native | delegates to native |
| .NET (desktop) | ✅ via `Makaretu.Dns.Multicast` | ✅ | ✅ |
| .NET (mobile / Catalyst) | delegates to native | delegates to native | delegates to native |

## When this isn't the right fit

- **You're shipping to a single device class.** No reason to wire
  offload — just don't set `offload.enabled`.
- **All your users have weak hardware and no peer to offload to.**
  Offload won't help. Pick a smaller model.
- **You have strong cloud-availability assumptions.** Offload is
  designed for the local-AI-first scenario. If your app already
  falls back to a cloud API on weak devices, that's its own thing —
  dvai-bridge offload doesn't replace it.
- **You can't host a rendezvous server.** Use LAN-only by leaving
  `rendezvousUrl` unset. Internet pairing requires
  [self-hosting](./self-hosting-rendezvous.md) — we don't operate
  a rendezvous service for the world.

## Limitations + roadmap

- **Browser as offload TARGET** is not supported. Browsers can't
  reliably accept inbound HTTP from cross-origin sources. Browsers
  are offload-source-only.
- **Rendezvous-WS-tunneled requests** are stubbed in v3.0.0-rc1 (LAN
  path is fully wired; internet path's WS-relay support lights up in
  v3.0.0 final). Track progress via the v3.0 milestone on GitHub.
- **Outgoing-offload routing in the native SDKs** — the v3.0 SDK
  packages ship `OffloadConfig` types, mDNS discovery, capability
  caches, and pairing primitives, but the per-SDK code that actually
  forwards outgoing `/v1/chat/completions` to a discovered peer
  isn't wired yet (commit `db5b750` for Android landed
  configuration + discovery + pairing types only). Until that
  finishes, host apps that want to test offload against a v3.1 Hub
  should call the Hub's URL directly with an OpenAI-compatible
  client (see [`examples/android-llama`](https://github.com/Westenets/dvai-bridge/tree/main/examples/android-llama)
  for a worked example). v3.1 finalization for each native SDK is
  tracked separately on GitHub.
- **Persistent pairing across reconnects** (no re-QR-scan after
  device reboot) is on the v3.1 roadmap.
- **CLI diagnostics tool** (`dvai-bridge cli peers`, `... probe`,
  etc.) is on the v3.1 roadmap.
- **Multi-instance horizontal scaling of the rendezvous server**
  (Redis-backed session store) is on the v3.2 roadmap. Until then,
  vertical scaling + a sticky LB handles ~50k concurrent sessions
  per instance.

## See also

- [Self-hosting the rendezvous server](./self-hosting-rendezvous.md) — operational walkthrough for the optional internet-path infrastructure.
- [Migration: v2.4 → v3.0](../migration/v2.4-to-v3.0) — what to update when upgrading.
- [RESEARCH.md §11](https://github.com/Westenets/dvai-bridge/blob/main/RESEARCH.md) — the design rationale (LAN-first, app-supplied vs rendezvous internet, why we don't ship a hosted service).
