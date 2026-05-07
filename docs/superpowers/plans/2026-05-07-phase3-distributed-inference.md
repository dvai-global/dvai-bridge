# Post-v2.4 Phase 3 Implementation Plan — Distributed Inference (v3.0.0)

**Spec:** [2026-05-07-phase3-distributed-inference-design.md](../specs/2026-05-07-phase3-distributed-inference-design.md) (rev 2)
**Date:** 2026-05-07 (initial) / 2026-05-07 (rev 2 — Plan B for internet path)
**Target tag:** v3.0.0 (final); v3.0.0-rc1 along the way for the core scaffolding.
**Branch:** dedicated `phase3/distributed-inference` (long-lived; merges to main when v3.0.0 ships).

This is the largest single piece of work since v2.0. Sequenced into 12 tasks (rev 2 added 3 tasks for the rendezvous server + QR-pair flow). Single-session execution is not realistic; this plan spans multiple sessions. Tasks 0–6 are the v3.0.0-rc1 backbone.

## Task ordering

```
0. Rendezvous server scaffold (rendezvous/ at repo root — pre-implementation, no library changes)
   ↓
1. Capability probe + cache (cross-platform JS-side first; native parity in 8)
   ↓
2. mDNS / DNS-SD discovery (Node + browser-stub; native parity in 8)
   ↓
3. Rendezvous client — WebSocket pairing (Node + browser; native parity in 8)
   ↓
4. Offload decision + proxy + structured-error (core, JS-side)
   ↓
5. Handshake auth + pairing storage (core; native parity in 8)
   ↓
6. New /v1/dvai/* endpoints in the embedded HTTP server (incl. pair-qr + pair-scan)
   ↓                                         (TAG: v3.0.0-rc1)
7. QR-code utilities (generation in core; scanning is host-app's responsibility)
   ↓
8. Per-SDK integration:
     8a. iOS native     (Mac SSH; mDNS via NWBrowser/Listener; QR via AVFoundation in example apps)
     8b. Android native (NsdManager; QR via CameraX in example apps)
     8c. RN             (delegates to native; surfaces config + QR-scan callback)
     8d. Flutter        (delegates to native; surfaces config + QR-scan callback)
     8e. .NET           (mDNS via Makaretu.Dns.Multicast on desktop; delegates on mobile)
     8f. Capacitor      (delegates; surfaces config in JS facade)
   ↓
9. Cross-host E2E testing
     - LAN: 2 devices on same Wi-Fi
     - Internet: 2 devices on different networks via deployed rendezvous server
   ↓
10. Docs:
      - docs/guide/distributed-inference.md (new) — user-facing guide
      - docs/guide/self-hosting-rendezvous.md (new) — self-hosting walkthrough
      - docs/migration/v2.4-to-v3.0.md
      - RESEARCH.md addendum on the offload pattern
      - RENDEZVOUS-REFERRALS.md (gitignored, repo root) — referral-link setup
   ↓
11. v3.0.0 release: bump root, sync versions, CHANGELOG [3.0.0],
    commit + tag + push + GH release.
```

---

## Task 0 — Rendezvous server scaffold (`rendezvous/`)

**Where:** new directory `rendezvous/` at monorepo root. Self-contained. NOT in `pnpm-workspace.yaml`.

### Files

```
rendezvous/
├── package.json           # private; own deps; no workspace refs
├── tsconfig.json
├── README.md              # one-click deploy buttons (Railway + DigitalOcean only)
├── DEPLOYMENT.md          # detailed self-hosting flow
├── .env.example           # PORT, HOST, SESSION_TTL_SECONDS, etc.
├── .gitignore             # node_modules, dist, .env
├── Dockerfile             # multi-stage; minimal production image
├── railway.json           # Railway template config
├── app.yaml               # DigitalOcean App Platform spec
├── src/
│   ├── server.ts          # entry point
│   ├── ws-relay.ts        # WebSocket session manager
│   ├── session.ts         # Session type + TTL handling
│   ├── messages.ts        # message-type discriminated union (TS types)
│   ├── health.ts          # GET /health handler
│   └── metrics.ts         # GET /metrics (optional)
├── tests/
│   ├── ws-relay.test.ts
│   └── session.test.ts
└── scripts/
    └── smoke.sh           # spins up + sends a synthetic pair flow
```

### Server protocol (in `src/messages.ts`)

```ts
type ClientMessage =
  | { type: "pair-source"; deviceId: string; deviceName: string; capability: Record<string, number>; ephemeralPubKey: string }
  | { type: "pair-target"; sessionId: string; deviceId: string; deviceName: string; capability: Record<string, number>; ephemeralPubKey: string }
  | { type: "inference-request"; sessionId: string; payload: any }
  | { type: "inference-response-chunk"; sessionId: string; payload: any }
  | { type: "inference-response-end"; sessionId: string }
  | { type: "error"; sessionId: string; message: string }
  | { type: "ping" };

type ServerMessage =
  | { type: "session-created"; sessionId: string; qrPayload: string; expiresAt: number }
  | { type: "peer-connected"; peerEphemeralPubKey: string; peerDeviceId: string; peerDeviceName: string }
  | { type: "peer-disconnected" }
  | { type: "relay"; from: "source" | "target"; payload: any }
  | { type: "error"; message: string }
  | { type: "pong" };
```

The server doesn't decrypt anything. It mediates the X25519 key exchange (just relays public keys) and then relays opaque payloads between source and target. Both peers do their own AEAD encryption with the derived shared key — the server never sees plaintext.

### Tests

- Unit: session creation, TTL expiry, message routing, malformed-input rejection.
- Integration (`smoke.sh`): start server, simulate source + target via two `wscat`-style clients, complete a synthetic pair + relay flow, exit 0.

### Done criteria

- `cd rendezvous && npm install && npm run build && npm start` works end-to-end.
- `bash rendezvous/scripts/smoke.sh` returns 0.
- README has working Railway + DigitalOcean deploy buttons (templated with `<REF>` placeholders that get filled from env vars at docs-build time).
- `Dockerfile` builds cleanly (`docker build -t rendezvous .`).

This task lands first because it's a pre-implementation artifact (the library will need it during integration testing). No library changes.

---

## Task 1 — Capability probe + cache

**Where:** `packages/dvai-bridge-core/src/capability/`

- `capability/probe.ts` — runs a 50-token completion against the active backend, measures decode tok/s, returns `CapabilityScore`.
- `capability/cache.ts` — abstract `CapabilityCache` interface + per-runtime concrete (browser IndexedDB, Node FS).
- `capability/heuristic.ts` — coarse static fallback before first probe.
- `capability/index.ts` — public surface: `getCapability(modelId)`, `probeCapability(modelId)`, `clearCapabilityCache()`.
- `capability/deviceId.ts` — stable per-install UUID.

Exposed on `DVAI`:
```ts
class DVAI {
  async probeCapability(): Promise<void>;
  async getCapability(modelId?: string): Promise<CapabilityScore>;
}
```

Tests: mock the backend's chat completion to return a fixed response with controlled timing; verify score calc is correct.

## Task 2 — mDNS / DNS-SD discovery (Node + browser-stub)

**Where:** `packages/dvai-bridge-core/src/discovery/`

- `discovery/types.ts` — `Peer`, `DiscoveryEvent`, `IDiscovery`.
- `discovery/mdns-node.ts` — Node-side via `multicast-dns` (optional dep; warn-and-skip if not installed).
- `discovery/mdns-browser.ts` — browser is a no-op.
- `discovery/static.ts` — known-peers static list.
- `discovery/composite.ts` — combines mDNS + static + rendezvous-paired into one stream.
- `discovery/advertiser.ts` — advertises THIS instance on mDNS.

Surface:
```ts
const discovery = createDiscovery({ serviceType: '_dvai-bridge._tcp.local', txtRecord: { /* ... */ } });
discovery.start();
discovery.peers$.subscribe(peer => ...);
```

Tests use `multicast-dns`'s in-process loopback.

## Task 3 — Rendezvous client (WebSocket pairing)

**Where:** `packages/dvai-bridge-core/src/rendezvous/`

- `rendezvous/client.ts` — connects to `${rendezvousUrl}` over WS; handles the source / target pairing flows.
- `rendezvous/keys.ts` — X25519 ephemeral key generation + shared-secret derivation (uses `@noble/curves` — small, audited).
- `rendezvous/qr-payload.ts` — encoding / decoding the QR payload (URL-safe base64 of compact JSON).
- `rendezvous/types.ts` — TS types matching `rendezvous/src/messages.ts` server-side.

Surface:
```ts
const client = createRendezvousClient({ url: 'wss://rendezvous.myapp.com' });
const session = await client.startAsSource({ deviceId, deviceName, capability });
console.log(session.qrPayload);  // app displays this as a QR code
const peer = await session.waitForPeer();  // resolves when target scans + completes handshake
// `peer` is now an `OffloadPeer` ready for use by the offload decider
```

Tests: spin up a local rendezvous server (Task 0's code), run two clients in-process, verify they pair successfully.

## Task 4 — Offload decision + proxy + structured-error

**Where:** `packages/dvai-bridge-core/src/offload/`

- `offload/decide.ts` — pure function: `(request, localCapability, peers, policy) → Decision`.
- `offload/proxy.ts` — given a `Decision.offload`, proxy the OpenAI request to `peer.baseUrl` (LAN) or via the rendezvous WS (internet) — same shape from the consumer's side.
- `offload/error.ts` — constructs the `no_capable_device` error.
- `offload/policy.ts` — per-request header parsing.

Tests: never overrides offload; require + no peer → error; prefer + slow local + fast peer → offload; prefer + slow local + no peer → local fallback.

## Task 5 — Handshake auth + pairing storage

**Where:** `packages/dvai-bridge-core/src/pairing/`

- `pairing/handshake.ts` — generate / verify HMAC; handle `POST /v1/dvai/handshake`.
- `pairing/store.ts` — persistent storage of approved pairings.
- `pairing/policy.ts` — calls host-app `onPairingRequest` for new origins.

Default: deny. Per-platform storage adapters land in Task 8.

## Task 6 — New `/v1/dvai/*` endpoints

**Where:** `packages/dvai-bridge-core/src/handlers/dvai/`

- `dvai/capability.ts` — `GET /v1/dvai/capability`.
- `dvai/handshake.ts` — `POST /v1/dvai/handshake`.
- `dvai/probe.ts` — `POST /v1/dvai/probe`.
- `dvai/peers.ts` — `GET /v1/dvai/peers`.
- `dvai/health.ts` — `GET /v1/dvai/health`.
- `dvai/pair-qr.ts` — `POST /v1/dvai/pair-qr` (initiate rendezvous session, return QR payload).
- `dvai/pair-scan.ts` — `POST /v1/dvai/pair-scan` (target device submits scanned QR payload).

**Gate after Task 6: tag `v3.0.0-rc1`.**

## Task 7 — QR-code utilities

**Where:** `packages/dvai-bridge-core/src/qr/`

- `qr/encode.ts` — generate a QR payload from `{rendezvousUrl, sessionId, ephemeralPubKey}`. Uses `qrcode` lib (small, no native deps).
- `qr/types.ts` — payload shape.

QR *scanning* lives in the host app (camera UI is platform-specific). The library exposes `dvai.completePairFromQrPayload(payload)` which the host calls after the camera lib decodes the QR.

---

## Task 8 — Per-SDK integration

Each sub-task adds:
- `OffloadConfig` type to the SDK's start-options.
- Platform-native mDNS + WebSocket clients (where applicable).
- Capability + pairing storage adapters.
- `onPairingRequest` event surface idiomatic to the platform.
- QR-payload generation API (scanning is host-app's responsibility).

### 8a — iOS native (Mac SSH driven)

- `packages/dvai-bridge-ios/Sources/DVAIBridge/Discovery/`: `NWBrowserDiscovery.swift`, `NWAdvertiser.swift`.
- `packages/dvai-bridge-ios/Sources/DVAIBridge/Rendezvous/`: `RendezvousClient.swift` (URLSessionWebSocketTask).
- Capability cache: `Application Support/dvai-bridge/capability.json`.
- Pairing UI: `pairingRequest` AsyncSequence.

### 8b — Android native

- `packages/dvai-bridge-android-shared-core/src/main/kotlin/.../discovery/`: `NsdDiscovery.kt`, `NsdAdvertiser.kt`.
- `packages/dvai-bridge-android-shared-core/src/main/kotlin/.../rendezvous/`: `RendezvousClient.kt` (OkHttp WebSocket).
- Capability cache: `applicationContext.cacheDir/dvai-bridge/capability.json`.
- Pairing UI: `Flow<PairingRequest>`.

### 8c — React Native

- `packages/dvai-bridge-react-native/src/index.ts` extends with `OffloadConfig`.
- TurboModule shim forwards to iOS/Android native.
- `pairingRequest` event via `addListener`.

### 8d — Flutter

- `packages/dvai-bridge-flutter/lib/src/offload.dart`.
- Pigeon channels extend with offload + pairing types.

### 8e — .NET

- `packages/dvai-bridge-dotnet/src/DVAIBridge/Offload/`.
- Desktop mDNS via `Makaretu.Dns.Multicast`. Mobile delegates to native.
- Pairing UI: `IAsyncEnumerable<PairingRequest>` desktop; `Task<bool>` callback mobile.

### 8f — Capacitor

- `packages/dvai-bridge-capacitor/src/index.ts` extends with `OffloadConfig`.
- 4 capacitor-* plugins surface the same.

## Task 9 — Cross-host E2E testing

**LAN test (Win + Mac via SSH):**
1. Device A (Windows) discovers Device B (Mac) via mDNS.
2. Pairing prompt on B; approve.
3. Chat completion on A offloads to B; SSE streams back.
4. B offline mid-stream → A surfaces stream_interrupted error.
5. With B offline + capability above threshold → no_capable_device JSON.
6. `X-DVAI-Offload: never` → A runs locally.

**Internet test:**
1. Deploy `rendezvous/` to Railway (using the deploy button + a fresh Railway account).
2. Configure two example apps (one Windows, one Mac) with `rendezvousUrl: <deployed url>`.
3. Generate QR on Windows; scan on Mac (manually paste QR payload via test harness — no actual camera in CI).
4. Verify offload works across networks.
5. Verify rendezvous server's metrics endpoint shows the session.

Document in `docs/development/distributed-inference-testing.md`.

## Task 10 — Docs

- `docs/guide/distributed-inference.md` (new): user-facing.
- `docs/guide/self-hosting-rendezvous.md` (new): server self-hosting walkthrough; embeds the deploy buttons; explains the env vars; covers scaling considerations.
- `docs/migration/v2.4-to-v3.0.md` (new): mostly "no breaking changes; new opt-in feature".
- `RESEARCH.md` addendum: §11 "Distributed Inference".
- `CHANGELOG.md` `[3.0.0]` section.
- **`RENDEZVOUS-REFERRALS.md`** (gitignored, repo root): step-by-step instructions for the project owner to:
  1. Sign up for the Railway affiliate program → get your unique referral code → plug into env var `RAILWAY_REFERRAL_CODE`.
  2. Sign up for the DigitalOcean referral program → get your unique referrer link → plug into env var `DIGITALOCEAN_REFERRAL_CODE`.
  3. Set `RAILWAY_TEMPLATE_ID` after publishing the rendezvous server as a Railway template.
  4. Run the docs-build with these env vars set; the deploy buttons in `rendezvous/README.md` and `docs/guide/self-hosting-rendezvous.md` will have the referral params filled in.
  5. Verify referral attribution by deploying through your own button, signing up with a fresh email, and checking Railway/DigitalOcean dashboards.

## Task 11 — v3.0.0 release

```bash
# Edit package.json: 2.4.x -> 3.0.0.
node scripts/sync-versions.js
node scripts/sync-package-meta.js
pnpm install --ignore-scripts
pnpm -r run build
bash scripts/build-all.sh

git add -A
git commit -m "chore(release): bump versions to 3.0.0 + tag v3.0.0 (Phase 3 — distributed inference)"
git tag -a v3.0.0 -m "v3.0.0 — distributed inference (LAN-first device offload + rendezvous-server-mediated internet pairing)"
git push origin main
git push origin v3.0.0
```

Final 3 gate:
- 2-device LAN test passes (Task 9).
- 2-device internet test passes via deployed rendezvous server.
- All 6 SDKs expose `offload` config.
- CHANGELOG + migration guide + RESEARCH addendum + self-hosting docs + RENDEZVOUS-REFERRALS.md all land.
- `git tag --list | tail -3` shows `v3.0.0`.
- `rendezvous/` deploys cleanly via both Railway and DigitalOcean buttons.

---

## What NOT to do

- Don't try to land all 12 tasks in one session — it's an 80+ hour scope.
- Don't host the rendezvous server ourselves as a public service. Ship the code; the app developer hosts.
- Don't add deploy buttons for platforms that don't pay us a referral. Vercel / Netlify / Render / AWS / Heroku get text-only mentions.
- Don't silently fall back to local on `X-DVAI-Offload: require`. Return the structured error.
- Don't change `/v1/chat/completions` wire shape. New endpoints are namespaced under `/v1/dvai/`.
- Don't make `offload.enabled` default-on. Opt-in only at v3.0.
- Don't issue auth tokens. The library doesn't run an auth system.
