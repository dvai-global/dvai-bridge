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

This page covers the consumer-facing config + behaviour. The full
design rationale is in
[`RESEARCH.md`](https://github.com/Westenets/dvai-bridge/blob/main/RESEARCH.md)
§11 ("Distributed inference"); the v3.0 spec is in
[`docs/superpowers/specs/2026-05-07-phase3-distributed-inference-design.md`](https://github.com/Westenets/dvai-bridge/blob/main/docs/superpowers/specs/2026-05-07-phase3-distributed-inference-design.md).

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
4. B generates a 256-bit pairing key and returns it. Stored on both
   sides (per-device).
5. From this point on, A's offload requests carry an
   `X-DVAI-Pairing: HMAC-SHA256(pairingKey, nonce + method + path + bodyHash)`
   header. B verifies before serving.
6. Pairings expire after `expireAfterDays` (default 30) of inactivity.
   Re-pair via fresh handshake.

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
