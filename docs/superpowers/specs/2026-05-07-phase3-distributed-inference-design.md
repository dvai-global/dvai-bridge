# Post-v2.4 Phase 3 — Distributed Inference (LAN-first device offload)

**Status:** Draft (2026-05-07) — pre-implementation. Targets v3.0.0.
**Date:** 2026-05-07
**Scope:** Add a "if my device is too weak for this model, find a stronger device on the same network running this library and offload to it" capability to the dvai-bridge family. LAN-first; internet path is opt-in via app-supplied auth context. Capability assessment is probe-based and cached. Returns a structured JSON error when no capable device is found. The HTTP wire surface stays unchanged — consumers pointing at `dvai.baseUrl` get the offloaded result transparently.

This is the first **major** version bump (v3.0.0). The OpenAI-compatibility surface is preserved; all v2.x consumer code keeps working unchanged. The new behaviour is opt-in via configuration.

## 1. Goals

1. **Same code, better hardware.** A consumer app reads `dvai.baseUrl` and writes OpenAI-compatible HTTP. Whether the request runs locally or on a peer device on the LAN, the consumer's code is identical. The library decides per-request.
2. **Transparent fallback.** If no capable peer is found, the library returns a deterministic structured error in the OpenAI error shape so callers can surface a single "no AI-capable device available" UX instead of a chain of cryptic timeouts.
3. **Zero auth dependency for the LAN path.** Two devices on the same Wi-Fi running the same library — same app or different — can discover and offload to each other without any account or token.
4. **App-supplied auth for the internet path.** When the host app has its own user auth, it can hand the library an opaque "list of this user's other devices + their endpoints" blob. The library uses that to attempt direct connections beyond the LAN. The library doesn't issue tokens, doesn't run a rendezvous server, doesn't touch the host app's identity model.
5. **Capability assessment that's not a lie.** A "is this device fast enough?" answer that's based on actual measurement, not on a hardcoded device-class lookup. Runs once on a per-(model, device) basis and caches the result.
6. **No new wire-format surface.** All discovery + offload happens over the same HTTP server the library already runs. New endpoints are namespaced under `/v1/dvai/`.

## 2. Non-goals

- **No rendezvous server we operate.** Internet-path discovery is the host app's responsibility; we provide the integration shape, not the infrastructure.
- **No QR-pairing as a built-in feature.** It's a documented pattern an app can implement on top, not a library feature. (Subject to revisit if a strong demand surfaces post-v3.0.)
- **No mesh-VPN integration as a code dependency.** Apps that want Tailscale / ZeroTier / Headscale can use them externally; the library doesn't ship a VPN client.
- **No automatic offload of all requests.** Offload is decided per request based on a capability score + threshold; consumer code can override per request via a header (`X-DVAI-Offload: never|prefer|require`).
- **No model-state migration between devices.** If a peer is mid-inference and drops, that request fails. We don't checkpoint and resume. The library retries on a different peer or falls back local per the policy.
- **No streaming-protocol invention.** The offload path is plain HTTP (with SSE for streamed completions) — same shape as the local path.
- **No payment or rate-limit awareness.** A peer accepts offload requests freely from any LAN device that authenticates via the discovery handshake (see §4.4). Apps that need throttling implement it externally.

## 3. The user-visible behaviour

```ts
// Consumer code (unchanged from v2.x):
const dvai = new DVAI({
  backend: "auto",
  modelId: "Llama-3.2-3B-Instruct-Q4_K_M",
  // NEW (opt-in) — the only new config knob:
  offload: {
    enabled: true,
    discoverLAN: true,           // mDNS in the local network
    minLocalCapability: 10,      // tok/s threshold; offload if below
    knownPeers: [                // app-supplied list (optional, internet path)
      { url: "https://my-other-device.example/v1", auth: { token: "…" } },
    ],
    onOffload: (peer) => console.log(`offloaded to ${peer.deviceName}`),
  },
});

await dvai.initialize();
// dvai.baseUrl is unchanged — points at the local server.
// Behaviour is unchanged for any request the local device CAN serve fast enough.

const r = await openai.chat.completions.create({
  model: "Llama-3.2-3B-Instruct-Q4_K_M",
  messages: [{ role: "user", content: "Hello!" }],
});
// If local capability < threshold AND a faster peer is reachable, the
// library proxies the request to the peer and streams the response back.
// If no capable peer found, returns:
// { error: { type: "no_capable_device", code: 503, message: "...",
//            checked: [{deviceId, capabilityScore, reason}, ...],
//            localCapability: 4.2, requiredAtLeast: 10 } }
```

## 4. Design

### 4.1 Capability assessment

A per-(model-id, device) capability score = an estimate of `tok/s` for that model on that device. Computed via:

1. **Cold-run probe.** First time a model is loaded on a device, run a fixed 50-token completion ("Generate a sentence about clouds.") to measure decode tok/s. Persist the result keyed by `(modelId, dvai-bridge-version)`. Re-probe if either changes.
2. **Static heuristic fallback.** If a probe hasn't run yet (e.g. cold start, model just-installed), use a coarse device-class score derived at runtime: NPU presence + CPU class + RAM + GPU class → coarse `expected tok/s` band. This is the conservative starting point; the probe refines it on first real use.
3. **Threshold comparison.** `minLocalCapability` (default `10` tok/s) is the cutoff below which the library considers the device too slow for this model and looks for a peer.

Cache lives in:
- Browser: IndexedDB under `dvai-bridge:capability:v1`.
- Node / Electron: `~/.cache/dvai-bridge/capability.json` (or `%LOCALAPPDATA%\dvai-bridge\capability.json` on Windows).
- iOS / Mac Catalyst: `Application Support/dvai-bridge/capability.json` via `FileManager`.
- Android: `applicationContext.cacheDir/dvai-bridge/capability.json`.
- .NET Desktop: `Environment.SpecialFolder.LocalApplicationData/dvai-bridge/capability.json`.

### 4.2 LAN discovery (mDNS / DNS-SD)

Each running dvai-bridge instance advertises a service:

- **Service type:** `_dvai-bridge._tcp.local`
- **TXT record fields:**
  - `dvaiVersion` — library SemVer.
  - `deviceId` — stable UUID per device install (cached in the same dir as capability).
  - `deviceName` — human-readable hint (e.g. iOS device name, Mac hostname).
  - `models` — comma-separated list of currently-loaded model IDs.
  - `capability` — JSON-encoded `{modelId: tokPerSec}` map of measured scores.
  - `port` — the local HTTP server port.
  - `secure` — `1` if TLS is in use, `0` otherwise (default: `0` for LAN).

**Per-platform implementation:**

- **iOS / macOS / Catalyst:** `NWBrowser` + `NWListener` (Network framework, iOS 12+).
- **Android:** `NsdManager` (built-in since API 16). For API 24+ floor, this is universally available.
- **Linux / desktop:** Avahi via `dbus-next` (Node) or P/Invoke into `libavahi-client` for .NET.
- **Windows:** Bonjour for Windows shipped with iTunes/Apple-Software-Update, OR fall back to a pure-managed mDNS implementation (`Makaretu.Dns.Multicast` for .NET, `multicast-dns` for Node).
- **Browser:** browsers don't speak mDNS. The browser-side library skips LAN discovery and only uses the `knownPeers` list. (Browser's `caps` are typically the most expensive — WebGPU-tier — so this is an acceptable asymmetry; in practice, browser apps are usually offloading TO native peers, not advertising themselves as offload targets.)

### 4.3 The offload decision (per request)

On each `chatCompletion` / `createStreamingResponse` call:

```
if (!offload.enabled) → local
else if (request.headers['X-DVAI-Offload'] == 'never') → local
else:
  localScore = capability(modelId, this device)
  peers = discovered peers + knownPeers, sorted by capability(modelId, peer) desc
  bestPeer = peers[0] if peers.length else null

  if (request.headers['X-DVAI-Offload'] == 'require'):
    if (bestPeer && bestPeer.score >= minLocalCapability) → offload to bestPeer
    else → return no_capable_device error

  else (default 'prefer'):
    if (localScore >= minLocalCapability) → local
    else if (bestPeer && bestPeer.score > localScore) → offload to bestPeer
    else (local is bad but no better peer):
      if (localScore > 0) → local (best we have)
      else → return no_capable_device error
```

`X-DVAI-Offload: prefer` is the default when offload is enabled. `never` overrides to force local. `require` overrides to refuse-rather-than-fallback.

### 4.4 The offload protocol

Offload happens by proxying the OpenAI HTTP request to the peer's `${peer.baseUrl}` with the same body and headers, plus:

- `X-DVAI-Origin: <originDeviceId>` — for the peer's audit log.
- `X-DVAI-Forwarded: 1` — the peer ignores its own offload routing for forwarded requests (no infinite loop).
- The discovery-handshake auth header (see below).

For streamed completions, the proxy forwards the SSE response chunk-by-chunk back to the original HTTP client. No buffering.

**Discovery-handshake auth (LAN):**

To prevent a malicious app on the LAN from offloading inference to your laptop without your consent, every peer-to-peer request carries an HMAC signed with a *pairing key*:

- **First contact:** when device A discovers device B via mDNS, A sends a small `POST /v1/dvai/handshake` request with `{originDeviceId, originDeviceName, originVersion}`. B stores the request in a "pending pairings" queue and surfaces a UI prompt to the user: "Device A is asking to use this device for AI inference. Allow / Deny / Always allow / Always deny." On approval, B emits a one-time `pairingKey` (256-bit random) and sends it back to A. From then on, A includes `X-DVAI-Pairing: <hmac(pairingKey, requestBody)>` on every offload request.
- **For LAN apps that share an account (same install):** The library can bypass the prompt if the device's stored `accountFingerprint` matches (computed from a config-supplied app-secret hash). Optional, host-app-driven.
- **Pairing storage:** the cache dir from §4.1, alongside the capability scores.

**Discovery-handshake auth (internet, via `knownPeers`):**

- The host app supplies the auth header per peer (e.g. `Authorization: Bearer <token>`). The library forwards it verbatim. No mDNS, no pairing handshake — the host app's auth model is authoritative.

### 4.5 The structured error response

When `no_capable_device` is the outcome, the response is OpenAI-error-shaped:

```json
{
  "error": {
    "type": "no_capable_device",
    "code": 503,
    "message": "No device with capability ≥ 10 tok/s for model Llama-3.2-3B-Instruct-Q4_K_M was reachable.",
    "checked": [
      {
        "deviceId": "self",
        "capabilityScore": 4.2,
        "reason": "below threshold"
      },
      {
        "deviceId": "ABCD-1234",
        "deviceName": "Mac Studio M4 Max",
        "capabilityScore": 0,
        "reason": "discovered via mDNS but unreachable (timeout after 3s)"
      }
    ],
    "localCapability": 4.2,
    "requiredAtLeast": 10,
    "requestId": "<request id>"
  }
}
```

Returned with HTTP 503 + `Retry-After: 30` so naive HTTP clients also handle it sensibly.

### 4.6 New `/v1/dvai/*` endpoints

Hosted by the local dvai-bridge HTTP server alongside the OpenAI surface:

- **`GET /v1/dvai/capability`** — returns this device's capability map.
- **`POST /v1/dvai/handshake`** — discovery-handshake initiation.
- **`POST /v1/dvai/probe`** — manual probe trigger (for diagnostics and the `dvai-bridge cli` tool).
- **`GET /v1/dvai/peers`** — returns the discovered peer list (read-only, for diagnostics + UI).
- **`GET /v1/dvai/health`** — basic liveness; used by peers for reachability checks before considering a peer "live".

## 5. Backwards compatibility

- v2.x consumer code that doesn't set `offload` keeps working unchanged. The default is `offload.enabled: false`.
- The HTTP surface gains the `/v1/dvai/*` namespace but doesn't change `/v1/chat/completions` etc.
- A v3.0 device discovers v2.x peers as "unsupported" (no mDNS advertisement → not visible) — they don't show up in peer lists; that's the right behaviour.

## 6. Risk + mitigation

- **R1: mDNS is blocked on enterprise networks.** Mitigation: graceful failure → fall back to `knownPeers`-only path; surfacing a diagnostic in the error.
- **R2: Capability probes drain battery on cold start.** Mitigation: probe runs at most once per (model, version), gated behind explicit `await dvai.probeCapability()` if the developer wants to pre-warm; otherwise lazy on first request that would benefit.
- **R3: A malicious LAN device probes / spams the handshake endpoint.** Mitigation: rate-limit handshake to 1/min per origin; auto-deny after 5 quick rejections from the same origin; user UI for revoking always-allowed peers.
- **R4: Streaming SSE through a proxy adds latency.** Mitigation: the proxy is a passthrough — no buffering, chunks forwarded as soon as they arrive. Round-trip overhead on a healthy LAN is sub-50ms which is below the human-noticeable threshold for streaming text.
- **R5: Per-platform mDNS implementations diverge.** Mitigation: the discovery code is isolated behind a `IDeviceDiscovery` interface per SDK; every platform has its own concrete implementation. We don't pretend one implementation works everywhere.
- **R6: Peer chooses to lie about its capability score.** Mitigation: peer-reported scores are advisory; we re-probe a peer with a small "reachability + decode" test before serving its first real offload request through it; mismatch → drop the peer.
- **R7: Network partition mid-stream.** Mitigation: the SSE proxy detects connection drop; the consumer sees a streaming error event in the OpenAI shape (`{error: {type: "stream_interrupted", ...}}`); the library can optionally retry on a different peer if `X-DVAI-Offload: prefer` is the policy.

## 7. Open questions / decisions

### Q1: Should LAN mDNS be on by default, or opt-in?

**Decision:** opt-in. `offload.enabled: false` by default. This is a v3.0 *capability*, not a behaviour change. Consumers who want it set the flag.

### Q2: Should we add a CLI tool for diagnostics?

**Decision:** yes, defer to a v3.1. A `dvai-bridge cli` that lists peers, runs probes, prints capability cache, etc. Not on the v3.0 critical path.

### Q3: Should the browser path support being an offload *target*?

**Decision:** no. Browsers can't accept inbound HTTP requests outside the same origin reliably. The browser is offload-source-only; offload targets are native devices.

### Q4: Should we use TLS for LAN-to-LAN traffic?

**Decision:** no by default; opt-in via config. LAN HTTP traffic is fine for local-loopback use. TLS adds cert provisioning friction. The handshake-HMAC protects against tamper. Apps that need TLS can supply a self-signed cert via `offload.tls = { cert: "...", key: "..." }`.

### Q5: How does the library expose the "user must approve a pairing" UI?

**Decision:** event hook. `offload.onPairingRequest = (peer) => Promise<boolean>`. Default: deny. The host app implements the UI (since UI is platform-specific). For headless / server contexts: never approve unless an `offload.autoApprove` predicate matches.

### Q6: What's the SDK surface for setting offload config?

**Decision:**
- JS / TS: `new DVAI({ offload: {...} })` — extend `DVAIConfig`.
- Swift: `StartOptions(offload: .init(enabled: true, ...))`.
- Kotlin: `StartOptions(offload = OffloadConfig(...))`.
- Dart: `start(offload: OffloadConfig(...))`.
- C#: `StartOptions { Offload = new OffloadConfig { ... } }`.

Same shape, idiomatic per language.

### Q7: How is the `pairingKey` invalidated?

**Decision:** explicit `dvai.unpair(deviceId)` API + a `pairings.expireAfterDays = 30` default. Re-pairing requires a fresh handshake.

### Q8: Should consumer apps be able to plug their own discovery mechanism?

**Decision:** yes. `offload.customDiscovery: () => Promise<Peer[]>` slot lets an app replace the default mDNS / `knownPeers` mix entirely. Useful for corporate networks with internal device registries.

### Q9: What's the default `minLocalCapability`?

**Decision:** 10 tok/s. Below this, the user experience of streaming text becomes painful. Configurable per-app.

## 8. Phased delivery

Even at v3.0, the full distributed-inference surface is a lot to land at once. Suggested sub-phases inside the v3 line:

- **v3.0.0:** Core implementation. JS / Node + iOS + Android + .NET Desktop. LAN-only via mDNS. `knownPeers` static config supported. Structured error response. Probe-based capability. Per-platform handshake auth. SDK surface in all 6 SDKs (web/JS, iOS, Android, RN, Flutter, .NET).
- **v3.0.x patches:** bug fixes surfaced during real-world LAN testing. Edge cases (multi-NIC hosts, IPv6 mDNS, captive portals).
- **v3.1.0:** CLI diagnostics tool. Auth-context patterns for the internet path (sample integrations with common auth providers). Mac Catalyst + RN + Flutter parity (these inherit from the underlying native paths, so mostly free, but verification is its own task).
- **v3.2.0+ (parked):** QR-pairing convenience layer. Optional rendezvous server (only if there's a clear case; we'd rather not host one).

## 9. Effort estimate

- **Spec + plan:** done with this document.
- **Core (`packages/dvai-bridge-core/`) + capability cache layer:** ~6 hours.
- **LAN discovery per platform:** ~4 hours each × 5 platforms (iOS, Android, .NET, Node, browser-noop) = ~20 hours.
- **Offload-decision + proxy + structured-error:** ~4 hours in core + ~1 hour per SDK to expose the config = ~10 hours total.
- **Handshake-auth UI hooks per SDK:** ~2 hours each × 5 = ~10 hours.
- **Per-SDK config-surface integration:** ~2 hours each × 6 = ~12 hours.
- **End-to-end testing across 2 hosts (Win + Mac):** ~6 hours.
- **Docs (guide page, migration v2.4.x → v3.0):** ~3 hours.

**Total wall-clock:** ~71 hours. With parallel agents: ~25-30 hours real-time. This is genuinely multi-week work, not one session.

For a single session: only the core + capability-cache + proxy + structured-error scaffolding land here (the v3.0-rc1 backbone). Per-SDK integrations land in subsequent sessions and ship as v3.0.0 final once all SDKs surface the config.

## 10. Acceptance criteria for v3.0.0

- A consumer app on Device A (low-capability) running with `offload.enabled: true` and a peer Device B (high-capability) on the same LAN: requests for a model both have loaded auto-route to B.
- Same setup but no peer reachable: requests return the structured `no_capable_device` JSON error with HTTP 503.
- Same setup but `X-DVAI-Offload: never` header: requests run locally even when slow.
- Capability probes run once per (model, device, version) and cache.
- Pairing handshake prompts the user the first time, remembers the decision per `expireAfterDays`.
- mDNS advertisement works on iOS, Android, Mac, Linux, Windows (with appropriate fallback library).
- All 6 SDKs (browser-react, browser-vanilla, capacitor, ios-native, android-native, react-native, flutter, .NET) expose the `offload` config in their idiomatic form.
- CHANGELOG entry, migration guide, RESEARCH.md addendum on the offload pattern.
