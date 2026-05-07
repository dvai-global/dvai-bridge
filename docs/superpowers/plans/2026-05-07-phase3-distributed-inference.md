# Post-v2.4 Phase 3 Implementation Plan — Distributed Inference (v3.0.0)

**Spec:** [2026-05-07-phase3-distributed-inference-design.md](../specs/2026-05-07-phase3-distributed-inference-design.md)
**Date:** 2026-05-07
**Target tag:** v3.0.0 (final), with v3.0.0-rc1 along the way for the core scaffolding.
**Branch:** dedicated `phase3/distributed-inference` (long-lived; merges to main when v3.0.0 ships).

This is the largest single piece of work since the v2.0 family launched. Sequenced into 9 tasks. Single-session execution is not realistic; this plan spans multiple sessions. Tasks 1–4 are the v3.0.0-rc1 backbone and *can* land in one heavy session.

## Task ordering

```
1. Capability probe + cache (cross-platform JS-side first; native parity in 6)
   ↓
2. mDNS / DNS-SD discovery (Node + browser-stub; native parity in 6)
   ↓
3. Offload decision + proxy + structured-error (core, JS-side)
   ↓
4. Handshake auth + pairing storage (core; native parity in 6)
   ↓
5. New `/v1/dvai/*` endpoints in the embedded HTTP server
   ↓                                         (TAG: v3.0.0-rc1)
6. Per-SDK integration:
     6a. iOS native     (Mac SSH; mDNS via NWBrowser/Listener)
     6b. Android native (NsdManager)
     6c. RN             (delegates to native; surface config)
     6d. Flutter        (delegates to native; surface config)
     6e. .NET           (mDNS via Makaretu.Dns.Multicast on desktop;
                         delegates to iOS/Android native on mobile)
     6f. Capacitor      (delegates; surface config in JS facade)
   ↓
7. Cross-host E2E testing (Win + Mac via SSH; 2-device offload smoke)
   ↓
8. Docs:
     - docs/guide/distributed-inference.md (new)
     - docs/migration/v2.4-to-v3.0.md
     - RESEARCH.md addendum on the offload pattern
   ↓
9. v3.0.0 release: bump root, sync versions, CHANGELOG [3.0.0],
   commit + tag + push + GH release.
```

---

## Task 1 — Capability probe + cache

**Where:** `packages/dvai-bridge-core/src/capability/`

- `capability/probe.ts` — runs a 50-token completion against the active backend, measures decode tok/s, returns a `CapabilityScore` `{tokPerSec, modelId, libraryVersion, deviceId, measuredAt}`.
- `capability/cache.ts` — abstract `CapabilityCache` interface + per-runtime concrete (browser IndexedDB, Node FS).
- `capability/heuristic.ts` — coarse static fallback when no probe has run yet.
- `capability/index.ts` — public surface: `getCapability(modelId): Promise<CapabilityScore>`, `probeCapability(modelId): Promise<void>`, `clearCapabilityCache()`.
- `capability/deviceId.ts` — stable per-install UUID with platform-appropriate persistence.

Exposed on `DVAI` instance:
```ts
class DVAI {
  async probeCapability(): Promise<void>;
  async getCapability(modelId?: string): Promise<CapabilityScore>;
  // ...existing API unchanged...
}
```

Tests under `packages/dvai-bridge-core/src/capability/__tests__/`. Mock the backend's chat completion to return a fixed response with controlled timing; verify the score calculation is correct.

## Task 2 — mDNS / DNS-SD discovery (Node + browser-stub)

**Where:** `packages/dvai-bridge-core/src/discovery/`

- `discovery/types.ts` — `Peer`, `DiscoveryEvent`, `IDiscovery` interface.
- `discovery/mdns-node.ts` — Node-side mDNS via `multicast-dns` (optional dep; warn-and-skip if not installed).
- `discovery/mdns-browser.ts` — browser is a no-op (returns empty peer list).
- `discovery/static.ts` — `knownPeers`-only discovery (no network probing).
- `discovery/composite.ts` — combines mDNS + static + custom into one peer stream.
- `discovery/advertiser.ts` — advertises THIS instance on mDNS. Constructs the TXT record from the spec.

Surface:
```ts
const discovery = createDiscovery({
  serviceType: '_dvai-bridge._tcp.local',
  txtRecord: { /* device + version + capability */ },
  knownPeers: [...],
});
discovery.start();
discovery.peers$.subscribe(peer => ...);  // observable
```

Tests use `multicast-dns`'s in-process loopback to verify two `Discovery` instances find each other.

## Task 3 — Offload decision + proxy + structured-error

**Where:** `packages/dvai-bridge-core/src/offload/`

- `offload/decide.ts` — pure function: `(request, localCapability, peers, policy) → Decision` where `Decision = { kind: "local" } | { kind: "offload", peer: Peer } | { kind: "no_capable_device", checked: [...] }`.
- `offload/proxy.ts` — given a `Decision.offload`, proxy the OpenAI request to `peer.baseUrl` and forward the response (incl. SSE streaming).
- `offload/error.ts` — constructs the structured `no_capable_device` error response in OpenAI shape.
- `offload/policy.ts` — per-request header parsing (`X-DVAI-Offload: never|prefer|require`).

Hooks into the existing handler pipeline so consumer code unchanged.

Tests cover: never overrides offload; require + no peer → error; prefer + slow local + fast peer → offload; prefer + slow local + no peer → local fallback.

## Task 4 — Handshake auth + pairing storage

**Where:** `packages/dvai-bridge-core/src/pairing/`

- `pairing/handshake.ts` — generate / verify the pairing-key HMAC; handle the initial `POST /v1/dvai/handshake` flow.
- `pairing/store.ts` — persistent storage of approved pairings (next to capability cache).
- `pairing/policy.ts` — calls the host-app `onPairingRequest` callback when a new origin appears.

Default `onPairingRequest` denies. Host apps wire their UI in.

Per-platform storage adapters land in Task 6.

## Task 5 — New `/v1/dvai/*` endpoints

**Where:** `packages/dvai-bridge-core/src/handlers/dvai/`

- `dvai/capability.ts` — `GET /v1/dvai/capability`.
- `dvai/handshake.ts` — `POST /v1/dvai/handshake`.
- `dvai/probe.ts` — `POST /v1/dvai/probe`.
- `dvai/peers.ts` — `GET /v1/dvai/peers`.
- `dvai/health.ts` — `GET /v1/dvai/health`.

Wire into the same handler-list the existing OpenAI endpoints use. MSW + HTTP transports both pick them up automatically (the handler list is shared).

**Gate after Task 5: tag `v3.0.0-rc1`** — the JS-side / core backbone is functionally complete; per-SDK integration is the next phase.

---

## Task 6 — Per-SDK integration

Each sub-task adds:
- The `OffloadConfig` type to the SDK's start-options.
- The platform-native mDNS implementation behind the `IDiscovery` interface (where applicable).
- Storage adapters for capability + pairing cache.
- A `onPairingRequest` event surface idiomatic to the platform.

### 6a — iOS native (Mac SSH driven)

- `packages/dvai-bridge-ios/Sources/DVAIBridge/Discovery/` — `NWBrowserDiscovery.swift` + `NWAdvertiser.swift`.
- `BoundServer.swift` extends with `offload: OffloadConfig?`.
- `StartOptions.swift` adds `offload`.
- Capability cache: `Application Support/dvai-bridge/capability.json` via `FileManager.default`.
- Pairing UI: emits a `pairingRequest` `AsyncSequence` event the host app subscribes to.

Tests in `Tests/DiscoveryTests.swift` verify NWBrowser sees the NWAdvertiser locally.

### 6b — Android native

- `packages/dvai-bridge-android-shared-core/src/main/kotlin/.../discovery/` — `NsdDiscovery.kt`, `NsdAdvertiser.kt`.
- `DVAIBridge.kt` extends with `OffloadConfig`.
- `StartOptions.kt` adds `offload`.
- Capability cache: `applicationContext.cacheDir / "dvai-bridge/capability.json"`.
- Pairing UI: `Flow<PairingRequest>` the host app collects.

Tests in `androidTest/.../DiscoveryTest.kt`.

### 6c — React Native

- `packages/dvai-bridge-react-native/src/index.ts` extends with `OffloadConfig`.
- TurboModule shim forwards offload config to the iOS / Android native impl.
- The `pairingRequest` event surfaces as a JS `addListener('pairingRequest', cb)`.

### 6d — Flutter

- `packages/dvai-bridge-flutter/lib/src/offload.dart` — Dart-side `OffloadConfig` + `PairingRequest`.
- Pigeon channels extend with the new types.
- iOS / Android native side delegates to 6a / 6b.

### 6e — .NET

- `packages/dvai-bridge-dotnet/src/DVAIBridge/Offload/` — `OffloadConfig.cs`.
- Desktop: mDNS via `Makaretu.Dns.Multicast` 0.27+ (cross-platform, pure-managed).
- iOS / Catalyst / Android: bind to the underlying iOS / Android native discovery.
- Pairing UI: `IAsyncEnumerable<PairingRequest>` for desktop; `Task<bool>` callback for mobile (because Compose / SwiftUI is on the hosting app's side).

### 6f — Capacitor

- `packages/dvai-bridge-capacitor/src/index.ts` extends with `OffloadConfig` (forwards to the underlying capacitor-llama / capacitor-foundation / etc plugin).
- The 4 capacitor-* plugins surface the same.

## Task 7 — Cross-host E2E testing

Set up two devices:
- Device A: Windows host (low capability for the test model).
- Device B: Mac via `ssh mac` (high capability).

Both run a small example app (the RN unified example from Phase 2 is ideal — covers iOS + Android + JS).

Verify:
1. Device A discovers Device B via mDNS.
2. Pairing prompt appears on Device B; approve.
3. Device A's chat completion request offloads to B; SSE chunks stream back.
4. Take Device B offline mid-stream → A surfaces the `stream_interrupted` error.
5. With B offline at request time, set `minLocalCapability` above A's score → A returns `no_capable_device` JSON.
6. Override with `X-DVAI-Offload: never` → A runs locally regardless.

Document in `docs/development/distributed-inference-testing.md`.

## Task 8 — Docs

- `docs/guide/distributed-inference.md` (new): user-facing guide. How to enable offload, the mDNS handshake, the pairing model, the structured error, the per-SDK config shape.
- `docs/migration/v2.4-to-v3.0.md` (new): migration guide. Most v2.x consumers don't need to change anything; new feature is opt-in.
- `RESEARCH.md` addendum: §11 "Distributed Inference" — explains the offload pattern, the LAN-first / app-supplied-auth-second design, and why it's the right shape vs. the alternatives (rendezvous server / VPN integration / QR pairing).
- `CHANGELOG.md` `[3.0.0]` section: feature description, BREAKING changes (none — backwards compatible), known limitations, migration pointer.

## Task 9 — v3.0.0 release

```bash
# Bump root.
# Edit package.json: 2.4.x -> 3.0.0.

# Cascade.
node scripts/sync-versions.js
node scripts/sync-package-meta.js

# Verify.
pnpm install --ignore-scripts
pnpm -r run build
bash scripts/build-all.sh

# Commit + tag.
git add -A
git commit -m "chore(release): bump versions to 3.0.0 + tag v3.0.0 (Phase 3 — distributed inference)"
git tag -a v3.0.0 -m "v3.0.0 — distributed inference (LAN-first device offload)"
git push origin main
git push origin v3.0.0

# GH Release (when on a host with gh CLI):
gh release create v3.0.0 --title "v3.0.0 — Distributed inference" \
  --notes-file <(awk '/^## \[3\.0\.0\]/,/^## \[2\.4/' CHANGELOG.md | sed '$d')
```

Final 3 gate:
- 2-device LAN test passes (Task 7).
- All 6 SDKs expose `offload` config.
- CHANGELOG + migration guide + RESEARCH addendum land.
- `git tag --list | tail -3` shows `v3.0.0`.
- Phase 3 fully shipped.

---

## What NOT to do

- Don't try to land all 9 tasks in one session — it's a 70+ hour scope. Tasks 1–5 are an aggressive single-session goal; Tasks 6+ span multiple sessions.
- Don't introduce a rendezvous server. That's deferred indefinitely (per §2 non-goal).
- Don't silently fall back to local on `X-DVAI-Offload: require`. Return the structured error.
- Don't change the `/v1/chat/completions` wire shape. The new endpoints are namespaced under `/v1/dvai/`.
- Don't make `offload.enabled` default-on. Opt-in only at v3.0.
- Don't issue auth tokens. The library doesn't run an auth system; LAN handshake is HMAC-of-pairing-key, internet path is host-supplied auth header.
