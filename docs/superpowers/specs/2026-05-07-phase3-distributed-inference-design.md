# Post-v2.4 Phase 3 — Distributed Inference (LAN-first device offload)

**Status:** Draft (rev 2 — 2026-05-07). Targets v3.0.0.
**Date:** 2026-05-07 (initial) / 2026-05-07 (rev 2)
**Scope:** Add a "if my device is too weak for this model, find a stronger device on the same network running this library and offload to it" capability to the dvai-bridge family. **LAN-first** via mDNS (no external infrastructure). **Internet path** is opt-in via a self-hostable rendezvous server (QR-pair-then-relay model) that ships in the same monorepo for the app developer to deploy where they want — if no `rendezvousUrl` is supplied during init, internet fallback is disabled. Capability assessment is probe-based and cached. Returns a structured JSON error when no capable device is found. The HTTP wire surface stays unchanged — consumers pointing at `dvai.baseUrl` get the offloaded result transparently.

This is the first **major** version bump (v3.0.0). The OpenAI-compatibility surface is preserved; all v2.x consumer code keeps working unchanged. The new behaviour is opt-in via configuration.

## Revision history

| Date       | Rev | Notes                                                                                                                                                                                                                                                                                                                                                                                                  |
|------------|-----|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 2026-05-07 | 1   | Initial spec. Internet path was Plan A (app-supplied auth context — host app's backend tells the library "user's other devices are X, Y, Z").                                                                                                                                                                                                                                                          |
| 2026-05-07 | 2   | User selected **Plan B** (QR pairing + rendezvous server) for the internet path. Server ships in `rendezvous/` at monorepo root, self-contained, deployable independently. Library config takes a `rendezvousUrl`; if unset, internet fallback is disabled. Public docs include self-hosting guide + one-click deploy buttons (Railway + DigitalOcean only — they have referral programs that pay us). |

---

## 1. Goals

1. **Same code, better hardware.** A consumer app reads `dvai.baseUrl` and writes OpenAI-compatible HTTP. Whether the request runs locally or on a peer device on the LAN (or on a paired remote device over the internet, if the app developer has deployed a rendezvous server), the consumer's code is identical. The library decides per-request.
2. **Transparent fallback.** If no capable peer is found, the library returns a deterministic structured error in the OpenAI error shape so callers can surface a single "no AI-capable device available" UX.
3. **Zero auth dependency for the LAN path.** Two devices on the same Wi-Fi running the library — same app or different — can discover and offload to each other without any account or token. Authorisation is via a one-time UI pairing prompt (handshake-HMAC after that).
4. **Internet path is the app developer's choice.** If they deploy the rendezvous server (we ship the code; deployment is theirs) and configure `rendezvousUrl`, paired devices over the internet can offload to each other. If they don't deploy it, internet fallback is disabled and only LAN works. The library never assumes a default rendezvous URL.
5. **Capability assessment that's not a lie.** A "is this device fast enough?" answer based on actual measurement, not on a hardcoded device-class lookup. Runs once on a per-(model, device) basis and caches the result.
6. **No new wire-format surface.** All discovery + offload happens over the same HTTP server the library already runs. New endpoints are namespaced under `/v1/dvai/`.
7. **Standalone server.** The rendezvous server lives in `rendezvous/` at the monorepo root. It has its own `package.json`, no workspace-package dependencies, its own README, its own deployment story. App developers can clone the monorepo and deploy *only* `rendezvous/`, or copy the directory out to their own infra.

## 2. Non-goals

- **No rendezvous server we operate as a service.** We ship the code; the app developer hosts it. Per-request relay traffic does NOT flow through dvai-bridge-controlled infrastructure.
- **No mesh-VPN integration as a code dependency.** Apps that want Tailscale / ZeroTier / Headscale can use them externally.
- **No automatic offload of all requests.** Offload is decided per request based on a capability score + threshold; consumer code can override per request via header (`X-DVAI-Offload: never|prefer|require`).
- **No model-state migration between devices.** If a peer is mid-inference and drops, that request fails. We don't checkpoint and resume.
- **No streaming-protocol invention.** The offload path is HTTP (with SSE for streamed completions). Internet path uses WebSocket as the transport between paired devices and the rendezvous server, but the *content* the consumer sees is still SSE-style chunks via the local OpenAI HTTP endpoint.
- **No payment or rate-limit awareness.** A peer accepts offload requests freely from any paired device. Apps that need throttling implement it externally.
- **No coverage of one-click-deploy platforms that don't pay us a referral.** Only Railway + DigitalOcean ship as deploy buttons in the public docs. Others (Vercel, Netlify, Render, AWS, Heroku) get text-only mentions in the deployment guide; consumers can use them but we don't earn a kickback so we don't headline them.

## 3. The user-visible behaviour

```ts
// Consumer code (mostly unchanged from v2.x):
const dvai = new DVAI({
  backend: "auto",
  modelId: "Llama-3.2-3B-Instruct-Q4_K_M",
  // NEW (opt-in) — the only new config knob:
  offload: {
    enabled: true,
    discoverLAN: true,                              // mDNS in the local network
    minLocalCapability: 10,                         // tok/s threshold; offload if below
    rendezvousUrl: "wss://rendezvous.myapp.com",    // OPTIONAL — internet path only if set
    onPairingRequest: async (peer) => /* show UI; return true/false */ true,
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
// If local capability < threshold AND a faster peer is reachable
// (via LAN mDNS OR via a pairing-via-rendezvous-server session),
// the library proxies the request to the peer and streams the
// response back. If no capable peer found, returns:
// { error: { type: "no_capable_device", code: 503, ... } }
```

## 4. Design

### 4.1 Capability assessment

A per-(model-id, device) capability score = an estimate of `tok/s` for that model on that device. Computed via:

1. **Cold-run probe.** First time a model is loaded on a device, run a fixed 50-token completion ("Generate a sentence about clouds.") to measure decode tok/s. Persist the result keyed by `(modelId, dvai-bridge-version)`. Re-probe if either changes.
2. **Static heuristic fallback.** If a probe hasn't run yet, use a coarse device-class score: NPU presence + CPU class + RAM + GPU class → coarse expected tok/s band.
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
  - `deviceName` — human-readable hint.
  - `models` — comma-separated list of currently-loaded model IDs.
  - `capability` — JSON-encoded `{modelId: tokPerSec}` map.
  - `port` — the local HTTP server port.
  - `secure` — `1` if TLS is in use, `0` otherwise (default: `0` for LAN).

**Per-platform implementation:**

- iOS / macOS / Catalyst: `NWBrowser` + `NWListener` (Network framework, iOS 12+).
- Android: `NsdManager` (built-in since API 16; universally available at our API 24+ floor).
- Linux / desktop: Avahi via `dbus-next` (Node) or P/Invoke into `libavahi-client` (.NET).
- Windows: Bonjour for Windows OR a pure-managed mDNS implementation (`Makaretu.Dns.Multicast` for .NET, `multicast-dns` for Node).
- Browser: skipped; browsers don't speak mDNS. Browser-side library uses only the rendezvous-paired peer list. (Browser is typically the offload **source**, not target.)

### 4.3 Internet discovery (QR pairing + rendezvous server)

When LAN discovery doesn't produce a candidate (different networks, mobile + laptop in different rooms, etc.), and `rendezvousUrl` is configured, the library can pair devices via the rendezvous server:

1. **Device A** (the source — the weak device that wants to offload) connects to `${rendezvousUrl}` over WebSocket and sends `{type: "pair-source", deviceId, deviceName, capability}`. The server returns `{sessionId, qrPayload}` where `qrPayload` is a short string the source displays as a QR code.
2. **Device B** (the target — the strong device) scans the QR code via the host app's camera UI. The QR payload contains `{rendezvousUrl, sessionId, sourceDeviceId, sourcePublicKey}`. Device B connects to the same `rendezvousUrl` over WebSocket and sends `{type: "pair-target", sessionId, deviceId, deviceName, capability}`.
3. **Server** verifies both sides claim the same `sessionId`, then mediates a key-exchange: both sides exchange ephemeral X25519 public keys via the server, derive a shared `pairingKey` independently, and send a "ready" signal.
4. **Server** stores nothing persistent — once both sides are ready, it relays subsequent `inference-request` / `inference-response-chunk` / `inference-response-end` / `error` frames between them. After 60s of inactivity, the session expires.
5. **Offload requests** flow as: `Device A` → WS frame to server → relay to `Device B` → `Device B` runs the inference locally → SSE chunks back as WS frames → server relays → `Device A` re-emits as SSE on its own local OpenAI endpoint to the consumer.

The rendezvous server is **stateless beyond active session memory**. No database. No accounts. No model uploads. It's a thin WebSocket relay.

**The pairing is one-shot** by default — sessions expire at TTL. Apps that want persistent pairing across reconnects extend the protocol with an `offload.persistPairing: true` option that stores the derived `pairingKey` in the same cache dir as capability scores, then reuses it on reconnect via a separate `resume-pairing` flow that doesn't require another QR scan.

### 4.4 The offload decision (per request)

On each `chatCompletion` / `createStreamingResponse` call:

```
if (!offload.enabled) → local
else if (request.headers['X-DVAI-Offload'] == 'never') → local
else:
  localScore = capability(modelId, this device)
  peers = LAN-discovered peers + paired-internet peers (via rendezvous), sorted by capability(modelId, peer) desc
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

LAN peers are preferred over internet peers when both are available at comparable scores (lower latency, no relay overhead).

### 4.5 The structured error response

When `no_capable_device` is the outcome:

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
    "requestId": "<request id>"
  }
}
```

Returned with HTTP 503 + `Retry-After: 30`.

### 4.6 New `/v1/dvai/*` endpoints

Hosted by the local dvai-bridge HTTP server alongside the OpenAI surface:

- `GET /v1/dvai/capability` — this device's capability map.
- `POST /v1/dvai/handshake` — LAN-pairing handshake initiation.
- `POST /v1/dvai/probe` — manual probe trigger.
- `GET /v1/dvai/peers` — discovered peer list (LAN + paired internet).
- `GET /v1/dvai/health` — basic liveness.
- `POST /v1/dvai/pair-qr` — generates a QR payload and starts a rendezvous session (returns `{sessionId, qrPayload, expiresAt}`).
- `POST /v1/dvai/pair-scan` — submits a scanned QR payload (the target device's camera UI calls this); the library handles the WebSocket dance internally.

### 4.7 The rendezvous server architecture

Lives at `rendezvous/` in the monorepo root.

- **Stack:** Node 22+, TypeScript, `ws` (WebSocket library), `fastify` for the small HTTP surface (health + metrics).
- **State:** in-memory only. `Map<sessionId, Session>`. Sessions expire at TTL (default 60s after last activity). No database.
- **Endpoints:**
  - `WS /pair` — the WebSocket endpoint both pairing devices connect to.
  - `GET /health` — `{status: "ok", activeSessions: N, uptimeSec: M}`.
  - `GET /metrics` — Prometheus-compatible metrics endpoint (optional, gated behind `METRICS_ENABLED=1`).
- **Configuration via env vars:**
  - `PORT` (default `8080`).
  - `HOST` (default `0.0.0.0`).
  - `SESSION_TTL_SECONDS` (default `60`).
  - `MAX_SESSIONS` (default `10000`).
  - `LOG_LEVEL` (default `info`).
  - `ALLOWED_ORIGINS` (CORS — default `*`).
  - `METRICS_ENABLED` (default `0`).
- **Deployment:** ships with a `Dockerfile`, `railway.json` (Railway template), `app.yaml` (DigitalOcean App Platform template), and a generic deployment guide for self-hosting elsewhere.
- **Resource floor:** designed to run on the smallest paid tier of any deploy platform — 256 MB RAM, single vCPU is plenty.

### 4.8 Server deployment & one-click buttons

`rendezvous/README.md` includes deploy buttons for the two referral platforms only:

- **[![Deploy on Railway](https://railway.app/button.svg)](https://railway.com/template/<TEMPLATE-ID>?referralCode=<REF>)** — Railway. 15% commission on referred user's first 12 months of invoices.
- **[![Deploy to DigitalOcean](https://www.deploytodo.com/do-btn-blue.svg)](https://cloud.digitalocean.com/apps/new?repo=https://github.com/Westenets/dvai-bridge/tree/main/rendezvous&refcode=<REF>)** — DigitalOcean. $25 referrer credit per qualified signup.

The `<TEMPLATE-ID>` and `<REF>` values are pulled from environment variables at docs-build time so the user can easily plug in their personal referral codes — full setup instructions in the gitignored `RENDEZVOUS-REFERRALS.md` at repo root.

Other platforms (Vercel, Netlify, Render, Heroku, AWS, Fly, Cloudflare) are mentioned in the deployment guide as text-only with a sample command, with no headlining "click this button" UI — they don't have referral programs that pay us.

## 5. Backwards compatibility

- v2.x consumer code that doesn't set `offload` keeps working unchanged. Default is `offload.enabled: false`.
- The HTTP surface gains the `/v1/dvai/*` namespace but doesn't change `/v1/chat/completions` etc.
- A v3.0 device discovers v2.x peers as "unsupported" (no mDNS advertisement → not visible).

## 6. Risk + mitigation

- **R1: mDNS is blocked on enterprise networks.** Mitigation: graceful failure → fall back to rendezvous-paired peers (if configured); surfacing a diagnostic in the error.
- **R2: Capability probes drain battery on cold start.** Mitigation: probe runs at most once per (model, version), gated behind explicit `await dvai.probeCapability()` if the developer wants to pre-warm; otherwise lazy on first request that would benefit.
- **R3: A malicious LAN device probes / spams the handshake endpoint.** Mitigation: rate-limit handshake to 1/min per origin; auto-deny after 5 quick rejections; user UI for revoking always-allowed peers.
- **R4: Streaming SSE through a proxy (LAN) or WebSocket (rendezvous) adds latency.** Mitigation: proxy is passthrough — no buffering. LAN overhead <50ms typical. Internet overhead depends on the rendezvous server's location relative to both devices; documented in the deployment guide.
- **R5: Per-platform mDNS implementations diverge.** Mitigation: discovery code isolated behind an `IDeviceDiscovery` interface per SDK; concrete impl per platform.
- **R6: Peer lies about its capability score.** Mitigation: peer-reported scores are advisory; we re-probe a peer with a small "reachability + decode" test before serving its first real offload request through it; mismatch → drop the peer.
- **R7: Network partition mid-stream.** Mitigation: SSE proxy detects connection drop; consumer sees a streaming-error event in OpenAI shape; library can optionally retry on a different peer.
- **R8: Rendezvous server abuse — someone pointing many devices at the user's deployed rendezvous.** Mitigation: server-side rate-limit (sessions/IP/min, default 10); the deployment guide explains how to configure stricter limits per environment.
- **R9: Server cost runs away on a successful app.** Mitigation: server is stateless beyond per-session memory; relay traffic is small (LLM token streams are KB/s, not MB/s); a $10/mo Railway/DO box handles ~1k concurrent sessions easily. The deployment guide includes a "scaling beyond this" §.
- **R10: QR scanning on devices without cameras (e.g. headless desktop).** Mitigation: the QR-pair flow is an *opt-in* UX. Apps targeting headless contexts use only the LAN path. The library docs make this constraint clear.

## 7. Open questions / decisions

### Q1: Should LAN mDNS be on by default, or opt-in?

**Decision:** opt-in. `offload.enabled: false` by default.

### Q2: Should we add a CLI tool for diagnostics?

**Decision:** yes, defer to v3.1. Not on the v3.0 critical path.

### Q3: Should the browser path support being an offload *target*?

**Decision:** no. Browsers can't accept inbound HTTP requests outside the same origin reliably.

### Q4: Should we use TLS for LAN-to-LAN traffic?

**Decision:** no by default; opt-in. LAN HTTP is fine. TLS adds cert provisioning friction. Handshake-HMAC protects against tamper. Apps that need TLS supply a cert via `offload.tls`.

### Q5: How does the library expose the "user must approve a pairing" UI?

**Decision:** event hook. `offload.onPairingRequest = (peer) => Promise<boolean>`. Default: deny.

### Q6: What's the SDK surface for setting offload config?

**Decision:**
- JS / TS: `new DVAI({ offload: {...} })` — extend `DVAIConfig`.
- Swift: `StartOptions(offload: .init(enabled: true, ...))`.
- Kotlin: `StartOptions(offload = OffloadConfig(...))`.
- Dart: `start(offload: OffloadConfig(...))`.
- C#: `StartOptions { Offload = new OffloadConfig { ... } }`.

### Q7: How is the `pairingKey` invalidated?

**Decision:** explicit `dvai.unpair(deviceId)` API + `pairings.expireAfterDays = 30` default.

### Q8: Should consumer apps be able to plug their own discovery mechanism?

**Decision:** yes. `offload.customDiscovery` slot.

### Q9: What's the default `minLocalCapability`?

**Decision:** 10 tok/s.

### Q10: Should the rendezvous server be a workspace package?

**Decision:** **No.** It lives at `rendezvous/` but is NOT in `pnpm-workspace.yaml`. It has its own `package.json` with no workspace deps. App developers can clone the monorepo and deploy *only* the `rendezvous/` directory (e.g. via `git sparse-checkout`), or use the platform's "deploy from subdirectory" feature (Railway / DigitalOcean both support this). This keeps the server self-contained.

### Q11: Should we host an "official" rendezvous server for testing?

**Decision:** **No.** We ship the server code; we don't host. App developers deploy to their own infrastructure. We may stand up a `rendezvous.deepvoiceai.co` for our own internal testing, but it's not documented as a public option — that would create a dependency on us we don't want, and would create an abuse vector we don't want to police.

### Q12: One-click-deploy buttons — which platforms?

**Decision:** **Railway + DigitalOcean only.** Both have referral programs that pay us a clear commission (Railway: 15% of referred user's first 12 months; DigitalOcean: $25 per qualified signup). Other platforms are listed in the deployment guide as text-only — consumers can use them, but we don't headline them since we don't earn anything.

The referral codes are pulled in at docs-build time from environment variables; setup instructions for the user are in `RENDEZVOUS-REFERRALS.md` at repo root (gitignored — private to the project owner).

## 8. Phased delivery

- **v3.0.0:** Core implementation. JS / Node + iOS + Android + .NET Desktop. LAN via mDNS. **Rendezvous server + QR pairing for internet path** (this revision adds it to v3.0.0 — was deferred to v3.2 in rev 1). Structured error response. Probe-based capability. Per-platform handshake auth. SDK surface in all 6 SDKs. Self-hosting docs + Railway / DigitalOcean deploy buttons.
- **v3.0.x patches:** bug fixes from real-world LAN + internet testing. Edge cases (multi-NIC hosts, IPv6 mDNS, captive portals, NAT-traversal failures).
- **v3.1.0:** CLI diagnostics tool. Persistent pairing across reconnects (`offload.persistPairing`). Mac Catalyst + RN + Flutter parity verification.
- **v3.2.0+:** Optional self-hosted rendezvous-cluster mode (Redis-backed session store) for apps with >10k concurrent users. STUN/TURN integration if the WebSocket-relay-only model proves costly at scale.

## 9. Effort estimate (revised)

- **Spec + plan revision:** done.
- **Rendezvous server (`rendezvous/`):** ~6 hours (Node + WebSocket relay + tests + Dockerfile + deploy templates + README with buttons + DEPLOYMENT.md).
- **Library core: capability cache:** ~6 hours.
- **Library core: LAN discovery per platform:** ~4 hours each × 5 platforms = ~20 hours.
- **Library core: rendezvous client (WebSocket pairing):** ~4 hours.
- **Library core: offload decision + proxy + structured-error:** ~6 hours.
- **Library core: handshake-auth + pairing storage:** ~4 hours.
- **Per-SDK config-surface integration (offload + QR scan UI hooks):** ~3 hours each × 6 SDKs = ~18 hours.
- **End-to-end testing across 2 hosts (Win + Mac):** ~6 hours (LAN) + ~4 hours (internet via deployed rendezvous) = ~10 hours.
- **Docs (guide page, migration v2.4.x → v3.0, self-hosting guide, RENDEZVOUS-REFERRALS.md):** ~5 hours.

**Total wall-clock:** ~85 hours. With parallel agents: ~30-40 hours real-time. This is genuinely multi-week work.

Single-session goal: rendezvous server scaffolded + spec/plan locked. Library-core implementation is the next big chunk; per-SDK integrations follow.

## 10. Acceptance criteria for v3.0.0

- LAN: a consumer app on Device A (low-capability) running with `offload.enabled: true` and a peer Device B (high-capability) on the same LAN: requests for a model both have loaded auto-route to B.
- Internet (with `rendezvousUrl` set + QR-paired Device B): same behaviour across networks.
- No peer reachable: requests return the structured `no_capable_device` JSON error with HTTP 503.
- `X-DVAI-Offload: never` header: requests run locally even when slow.
- Capability probes run once per (model, device, version) and cache.
- Pairing handshake prompts the user the first time, remembers the decision per `expireAfterDays`.
- mDNS advertisement works on iOS, Android, Mac, Linux, Windows.
- All 6 SDKs expose the `offload` config in their idiomatic form.
- `rendezvous/` deploys cleanly on Railway and DigitalOcean (verified via the one-click buttons).
- CHANGELOG entry, migration guide, RESEARCH.md addendum, self-hosting docs, gitignored RENDEZVOUS-REFERRALS.md with setup instructions.
