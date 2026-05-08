# Changelog

All notable changes to this project are documented here. This project
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [3.1.0] — 2026-05-08

Phase 4 — **DVAI Hub**. The strong-peer side of distributed inference,
packaged as a brand-neutral installable desktop utility. Same wire
protocol as v3.0; the difference is the user-facing artefact: instead
of "embed the strong-peer code in your own app," ship a small
tray-resident utility that any DVAI-enabled mobile app on the same Wi-Fi
can pair with. **Backwards compatible**: every v3.0 SDK keeps working
unchanged.

See `docs/guide/dvai-hub.md` for the user-facing design,
`hub/DEVELOPER-FORK.md` for the developer fork story, and
`docs/development/distributed-inference-testing.md` for the E2E
verification procedure.

### Added

- **DVAI Hub desktop utility** (`hub/`) — Tauri 2 shell + Node sidecar
  bridging via JSON-RPC. Tray-resident, single-instance. First-run
  pairing wizard, dashboard with audit log + manual peer controls,
  pause / resume, autostart on login.
  - **Sidecar packaging via Bun** — the Node peer-mode server is
    bundled into a single-file native binary (`bun build --compile`)
    and shipped as Tauri's `externalBin`. No `node` install required
    on the user's machine.
  - **Cross-platform installers** — Windows MSI, macOS DMG (arm64),
    Linux .deb / .rpm. Built by
    `.github/workflows/dvai-hub-release.yml` on every `v3.1.*` tag.
  - **Brand-neutral identity** — the Hub identifies itself to mobile
    apps with the host's machine name, not "DVAI." End users see
    "Pair with Mum's MacBook," not "Pair with deepvoiceai-something."
- **Per-app audit log** at `~/.dvai-hub/apps/<appId>/audit.log` —
  every cross-device inference request is recorded with timestamp,
  app ID, peer device, model, and response code. Privacy: log is
  local-only, never leaves the device.
- **`co.deepvoiceai.dvai-bridge.onnxruntime` + `.mlnet`** — optional
  .NET 10 LTS NuGet slices. Hosts pulling these in get ONNX Runtime
  GenAI / ML.NET as additional backends in the auto-selection mix.
- **Mac Catalyst** routing — .NET MAUI Mac Catalyst now inherits the
  same backend matrix as iOS native (Foundation Models / CoreML /
  MLX / Llama).

### Changed

- **Documentation site** has been audited end-to-end. All references
  to internal `docs/superpowers/*.md` spec/plan files have been
  replaced with pointers to the public API reference + relevant
  guides. `docs/guide/introduction.md` now lists every v3.1 platform
  and framework.
- **Native SDK install snippets** in `docs/guide/{android-native,
  ios-native,react-native,flutter,dotnet}-sdk.md` updated to v3.0.0
  (was 1.8 / 2.0 / 2.1 / 2.3 / 2.4 depending on which platform shipped
  most recently before the v3 cut).

### Notes

- **Code-signing is deferred** for v3.1.0. Both the GitHub Actions
  signing/notarization steps and the Tauri update-signing keypair
  are gated on secret presence; missing secrets just produce
  unsigned artefacts. End users will see SmartScreen / Gatekeeper
  warnings on first launch; tracked persistently in `TODO.md`.
- **macOS arm64 only** for v3.1.0 (`aarch64-apple-darwin`). x86_64
  Mac support follows in a v3.1.x patch once Bun's universal-binary
  story stabilizes.
- **Linux ships as `.deb` / `.rpm` only** for v3.1.0. AppImage is
  fundamentally fighting `bun build --compile`'s near-static binary
  layout — `linuxdeploy-plugin-gtk` runs `ldd` on the Bun-bundled
  sidecar, gets exit code 1, and aborts. AppImage support follows
  once we have a different sidecar bundling strategy on Linux
  (tracked in `TODO.md`).

## [3.0.0] — 2026-05-07

Phase 3 — distributed inference. The first major-version bump since
v2.0.0. **Backwards compatible**: v2.x consumer code that doesn't set
`offload` keeps working unchanged. The version major changed because
v3.0 introduces a substantial new capability (cooperative inference
across the user's devices), not because anything broke.

See `docs/migration/v2.4-to-v3.0.md` for the upgrade path,
`docs/guide/distributed-inference.md` for the user-facing design,
`docs/guide/self-hosting-rendezvous.md` for the optional internet-path
infrastructure, and `docs/development/distributed-inference-testing.md`
for the 2-device E2E verification procedure.

### Added — JS-side core (committed 8663573 + 82cba0f)

- **`@dvai-bridge/core` Phase 3 modules** under `src/`:
  - **`capability/`** — probe-based + heuristic-fallback capability
    assessment + per-runtime persistent score cache (IndexedDB browser
    / Node FS / in-memory). Stable per-install device ID.
  - **`discovery/`** — peer discovery types + Node mDNS via
    `multicast-dns` (optional dep) + browser no-op stub +
    static-list source + composite layer.
  - **`rendezvous/`** — WebSocket client for the rendezvous server.
    X25519 ephemeral key exchange via `@noble/curves` (small, audited,
    no native deps). QR-payload encode/decode.
  - **`offload/`** — pure `decide()` function. LAN peers preferred over
    rendezvous at comparable scores. Per-request `X-DVAI-Offload`
    header (`never | prefer | require`, default `prefer`). Structured
    `no_capable_device` response in OpenAI-error shape (HTTP 503 +
    `Retry-After: 30`).
  - **`pairing/`** — HMAC-SHA256-signed handshake auth via WebCrypto.
    256-bit pairing keys. Persistent storage adapters. `PairingPolicy`
    coordinates host-app `onPairingRequest` callback (default: deny)
    with TTL-expiring persistent state.
  - **`handlers/dvai/`** — 7 new HTTP routes: `health`, `capability`,
    `peers`, `probe`, `handshake`, `pair-qr`, `pair-scan`.
  - **`qr/`** — QR-payload encoder + `dvai-bridge://pair?p=…` deep-link
    helpers.
- **`DVAIConfig.offload?: OffloadConfig`** — opts the library into
  Phase 3 behaviour. Default unset = v2.x exactly. When `enabled: true`,
  `initialize()` brings up the capability cache + composite discovery
  + pairing policy; `unload()` tears them down.
- **`DVAI` instance methods**: `probeCapability()`, `getCapability(modelId?)`,
  `getPeers()`. All no-op when offload is off.
- **`@dvai-bridge/core` new dep**: `@noble/curves ^1.6.0`.

### Added — rendezvous server (committed 9717e3f, 7938659)

- **`rendezvous/`** at monorepo root — self-hostable WebSocket relay
  server. ~700 LOC of Node + Fastify + `@fastify/websocket` + `ws`.
  Stateless beyond per-session memory; no DB; no auth tokens; no
  plaintext inference data passes through (peers do their own AEAD).
- Ships with `Dockerfile` (multi-stage, ~120 MB) + `railway.json` +
  `app.yaml` deploy templates + 14/14 unit tests + smoke script.
- Publicly self-hostable via one-click Railway / DigitalOcean buttons.
  Other platforms (Fly, Render, Cloud Run, App Runner, Kubernetes,
  bare-VM Docker) documented in `rendezvous/DEPLOYMENT.md` and the
  public guide.

### Added — per-SDK integration (Phase 3 Task 8)

- **iOS native** (`@dvai-bridge/ios`, committed d830416 + 95702c0 +
  8994edf + b3cf18d): `OffloadConfig` Swift struct on `StartOptions`;
  mDNS via Apple's Network framework (`NWBrowser` + `NWListener`);
  capability cache under `Application Support/dvai-bridge/`; pairing
  via CryptoKit HMAC-SHA256; `pairingRequests: AsyncStream<PairingRequest>`
  for SwiftUI. 15/15 OffloadTests pass on iPhone 16 simulator (iOS 18.5).
- **Android native** (`co.deepvoiceai:dvai-bridge`, committed db5b750):
  `OffloadConfig` data class on `StartOptions`; mDNS via `NsdManager`;
  capability cache under `applicationContext.cacheDir/dvai-bridge/`;
  pairing via `javax.crypto.Mac` HMAC-SHA256;
  `pairingRequests: SharedFlow<PairingRequest>` for Compose. 46/46
  tests pass (39 new for Phase 3 Task 8b).
- **React Native** (`@dvai-bridge/react-native`), **Flutter**
  (`dvai_bridge`), **Capacitor** (`@dvai-bridge/capacitor` + 4
  variants) (committed 3bb17c1): thin facades over the iOS / Android
  native pairing surfaces. 15 (RN) + 34 (Flutter) + 16 (Capacitor)
  tests pass.
- **.NET** (`co.deepvoiceai.dvai-bridge*`, committed be7fa0d):
  `OffloadConfig` C# class on `StartOptions`; desktop mDNS via
  `Makaretu.Dns.Multicast`; capability cache under
  `Environment.SpecialFolder.LocalApplicationData/dvai-bridge/`;
  pairing via `System.Security.Cryptography.HMACSHA256`;
  `PairingRequests: IAsyncEnumerable<PairingRequest>` for desktop;
  `OnPairingRequest: Func<PairingRequest, Task<bool>>` callback for
  mobile. 62/62 OffloadTests + 7/7 Desktop.Tests pass on Windows; iOS +
  Mac Catalyst slices (`net10.0-ios26.4` + `net10.0-maccatalyst26.4`)
  build clean on Mac via SSH.

### Added — public docs

- **`docs/guide/distributed-inference.md`** (new) — quick start +
  `OffloadConfig` reference + per-request header + capability assessment
  + structured error shape + per-platform support matrix +
  when-not-to-use.
- **`docs/guide/self-hosting-rendezvous.md`** (new) — server self-hosting
  walkthrough; one-click deploy buttons (Railway / DigitalOcean only —
  the two platforms with referral programs that pay us); detailed
  per-platform instructions for everything else (Fly, Render, Vercel/
  Netlify caveats, AWS App Runner / ECS, GCR, K8s, bare-VM Docker).
- **`docs/migration/v2.4-to-v3.0.md`** (new) — backwards-compatible
  upgrade path; per-stack migration snippets for JS / iOS / Android /
  RN / Flutter / Capacitor / .NET; operational notes.
- **`docs/development/distributed-inference-testing.md`** (new) —
  2-device E2E test procedure for the v3.0 verification matrix (LAN
  + internet via deployed rendezvous + structured-error path +
  pairing flow + network-partition handling).
- **`docs/reference/api.md`** — `DVAIConfig` table gains `offload`
  row + new `OffloadConfig` section with per-field reference, X-DVAI-
  Offload header semantics, Peer type, no_capable_device error shape,
  new DVAI instance methods.
- **VitePress sidebar** gains "Distributed Inference (v3.0)" + "Self-
  Hosting Rendezvous (v3.0)" + "v2.4 → v3.0" + "Distributed Inference
  Testing (v3.0)" entries.

### Added — research paper (committed effbb1b)

- **`RESEARCH.md` restructured** — v3 capabilities are now first-class
  throughout, not a §11 addendum. New §3 "The Three Gaps" gives
  explicit gap-then-solution framing. §7 "Distributed Inference"
  promoted from the back to a first-class architecture section.
- **4 SVG figures refreshed**: fig1 (5-layer v3 architecture with v3
  plane as a dashed overlay), fig2 (6-column per-platform decision
  tree covering all 9 backends), fig3 (sequence with v3 offload-
  decision branch + 3 terminal paths). NEW fig7-rendezvous-flow.svg
  (4-phase QR-pair sequence diagram with privacy property called out).

### Changed — version bump

- All 36 packages bump 2.4.2 → 3.0.0 in lockstep via
  `scripts/sync-versions.js`. Backwards compatible — no consumer
  code changes required for the v2.4 → v3.0 transition.

### Removed

Nothing. v3.0 is purely additive.

### Deprecated

Nothing. Every v2.x API surface remains supported.

### Known limitations (v3.0)

- **Browser-as-target** unsupported. Browsers can't reliably accept
  inbound HTTP across origins; browser is offload-source-only via
  rendezvous.
- **Mid-stream model migration** not supported. If a peer drops
  mid-inference, that request fails. The library can optionally retry
  on a different peer per the `X-DVAI-Offload: prefer` policy.
- **Persistent rendezvous-pairing across reconnects** not yet
  supported (one-shot per session by default). Roadmap: v3.1.
- **CLI diagnostics tool** (`dvai-bridge cli peers`, `... probe`)
  not yet shipped. Roadmap: v3.1.
- **Multi-instance horizontal scaling of the rendezvous server**
  (Redis-backed session store) not yet supported. Roadmap: v3.2.
- **iOS / Android native discovery in the .NET MAUI slice**: stubbed
  with a `Debug.WriteLine` warning today; lights up automatically
  when the .NET binding gains access to the iOS Swift `NWBrowser`
  + Android Kotlin `NsdManager` surfaces.

### Distribution

- No registry publishes happen as part of v3.0.0. The tag is
  internal-development-only at this point. The user runs the publish
  flow per `PUBLISHING.md` when ready to launch (npm + Maven + NuGet
  + pub.dev).

---

---

## [3.0.0-rc1] — 2026-05-07

Phase 3 backbone — the JS-side core for distributed inference.
Tagged as a release-candidate so the per-SDK integration work
(Tasks 8a–8f) can target a stable core API. v2.x consumer code
that doesn't set `offload` is unchanged.

### Added

- **`@dvai-bridge/core` Phase 3 modules** (committed `8663573`):
  - **`capability/`** — probe-based + heuristic-fallback capability
    assessment + per-runtime persistent score cache (IndexedDB browser
    / Node FS / in-memory). Stable per-install device ID.
  - **`discovery/`** — peer discovery types + Node mDNS via
    `multicast-dns` (optional dep) + browser no-op stub +
    static-list source + composite layer.
  - **`rendezvous/`** — WebSocket client for the rendezvous server.
    X25519 ephemeral key exchange via `@noble/curves`. QR-payload
    encode/decode. Source-side `startAsSource()` returns a
    `PairingSession`; target-side `joinAsTarget()` completes the
    handshake and returns the derived shared secret.
  - **`offload/`** — pure `decide()` function (`(config, modelId,
    localCapability, peers, header) → Decision`). LAN peers preferred
    over rendezvous at comparable scores. Per-request
    `X-DVAI-Offload` header (`never | prefer | require`, default
    `prefer`). Structured `no_capable_device` response in OpenAI-error
    shape (HTTP 503 + `Retry-After: 30`).
  - **`pairing/`** — HMAC-SHA256-signed handshake auth via WebCrypto.
    256-bit pairing keys. Persistent storage adapters (IndexedDB +
    Node FS + in-memory). `PairingPolicy` coordinates the host-app
    `onPairingRequest` callback (default: deny) with TTL-expiring
    persistent state.
  - **`handlers/dvai/`** — 7 new HTTP routes: `health`, `capability`,
    `peers`, `probe`, `handshake`, `pair-qr`, `pair-scan`. The first
    five are wired; the last two return 501 in rc1 — they light up
    once the per-SDK QR-pairing UI surface lands in Tasks 8a–8f.
  - **`qr/`** — QR-payload encoder + `dvai-bridge://pair?p=…`
    deep-link helpers. Generation-only; scanning is the host app's
    responsibility (camera UI is platform-specific).
- **52 / 52 new tests passing** across `capability` (12), `discovery`
  (6), `rendezvous-keys` (6), `offload-decide` (16), `pairing` (12).
- **`@dvai-bridge/core` new dep**: `@noble/curves ^1.6.0`. Small
  (~5 KB), audited, no native deps.
- **`@dvai-bridge/core` `DVAIConfig.offload`** (committed `82cba0f`)
  — opts the library into Phase 3 behaviour. Default unset = v2.x
  exactly. When `enabled: true`, `initialize()` brings up the
  capability cache + composite discovery + pairing policy; `unload()`
  tears them down.
- **`@dvai-bridge/core` `DVAI` instance methods**: `probeCapability()`,
  `getCapability(modelId?)`, `getPeers()`. All no-op when offload is
  off.
- **`rendezvous/`** at monorepo root (committed `9717e3f`) —
  self-hostable WebSocket relay server. ~700 LOC. Stateless beyond
  per-session memory; no DB; no auth tokens; no plaintext inference
  data passes through (peers do their own AEAD). Ships with
  `Dockerfile` + `railway.json` + `app.yaml` deploy templates.
  14/14 unit tests passing.
- **Public docs**:
  - `docs/guide/distributed-inference.md` (new) — quick start +
    `OffloadConfig` reference + per-request header + capability
    assessment + structured error shape + per-platform support
    matrix + when-not-to-use.
  - `docs/guide/self-hosting-rendezvous.md` (already shipped in
    `7938659`; folded in DEPLOYMENT.md content for the public site).
  - `docs/migration/v2.4-to-v3.0.md` (new) — backwards-compatible
    upgrade path + per-stack migration snippets for JS / iOS /
    Android / RN / Flutter / .NET + operational notes.
  - `docs/reference/api.md` — `DVAIConfig` table gains `offload`
    row + new `OffloadConfig` section with per-field reference + new
    `DVAI` instance methods.
  - VitePress sidebar gains "Distributed Inference (v3.0)" under
    Guide + "v2.4 → v3.0" under Migration Guides.
- **`RESEARCH.md` §11** (new) — "Distributed Inference (v3.0+)".
  Covers the structural choices (LAN-first via mDNS; opt-in
  rendezvous server we ship as code, not as a service), capability
  probes vs. published benchmarks (revisit of §6.11), privacy
  properties of the offload path, what v3.0 deliberately does NOT
  do (no hosted relay, no auth tokens, no mesh-VPN integration, no
  browser-as-target, no mid-stream model migration). PDF regenerated
  (~1.0 MB).

### Changed

- **`@dvai-bridge/core` package.json** gains `@noble/curves` as a
  hard dep; bumps to 2.4.2.
- **All 36 packages** bump 2.4.1 → 2.4.2 in lockstep via
  `scripts/sync-versions.js`. The v3.0.0-rc1 tag points at commit
  `8663573` (the Phase 3 backbone); the per-package `version` fields
  stay at 2.4.2 until the v3.0.0 final tag lands.

### Distribution

- No registry publishes happen as part of v3.0.0-rc1. The tag is
  internal-development-only; the final v3.0.0 release will
  consolidate this rc + the per-SDK integrations + the 2-device E2E
  verification.

### What's pending for v3.0.0 final

- **Per-SDK integration** (Tasks 8a–8f) — surface `OffloadConfig` in
  the iOS / Android / RN / Flutter / .NET / Capacitor SDKs with
  platform-native discovery + pairing. In flight via parallel agents.
- **2-device E2E test** (Task 9) — LAN (Win + Mac via SSH) + via a
  deployed rendezvous server.
- **CHANGELOG `[3.0.0]` consolidation** + final v3.0.0 tag.

---

## [2.4.2] — 2026-05-07

Phase 2 example-matrix work surfaced four library-side fixes during
example construction. Bundled here so the fixes are available in a
patch release before v3.0.0 ships.

### Fixed

- **`@dvai-bridge/core`** — wired `node-llama-cpp` as the native Node
  backend. New `NodeLlamaCppBackend.ts`; `BackendType` widened to
  include `"native"`; `DVAI.initializeBackend()` resolves the native
  path via the existing `nativeModelPath` / `nativeContextSize` /
  `nativeGpuLayers` / `nativeThreads` config. (Surfaced by Phase 2
  Task 1's `examples/node-llama-cpp/`.)
- **`@dvai-bridge/core`** — native backend auto-derives `modelId`
  from the GGUF basename when not customised, so OpenAI responses
  echo a meaningful name (e.g. `Llama-3.2-1B-Instruct-Q4_K_M`)
  instead of the WebLLM placeholder.
- **All 5 Android packages** (`dvai-bridge-android` umbrella +
  `shared-core` + `llama-core` + `mediapipe-core` + `litert-core`)
  — added a `compileSdkOverride` Gradle property (default `36`,
  falls to `35` cleanly). Works around an AGP 9.2.0 + compileSdk 36
  + Windows-host bug in Android's `parseLocalResources` task that
  crashes parsing `android-36/data/res/values/public-final.xml`.
  Mac builds clean at compile-sdk 36; Windows consumers can pass
  `-PcompileSdkOverride=35` to sidestep. The new
  `scripts/android-publish-local.ps1` (Windows companion to the
  bash version) forwards the property automatically.
- **`DVAIBridge.iOS.csproj`** — TFM bumped `26.2` → `26.4`. The
  .NET 10.0.203 SDK shipped only `Microsoft.iOS.Sdk.net10.0_26.0`
  and `_26.4`; `_26.2` was retired between SDK 10.0.200 and 10.0.203.
  Building the iOS / Mac Catalyst slice on the current SDK now
  succeeds. Runtime floor stays at iOS 15.1 / Mac Catalyst 15.1; only
  the build TPV moved. `docs/guide/dotnet-sdk.md` consumer-facing TFM
  strings updated in lockstep.
- **`packages/dvai-bridge-dotnet/global.json`** SDK pin bumped from
  `10.0.100` → `10.0.203` (matches the documented contributor floor;
  `rollForward: latestFeature` continues to allow newer feature bands).

### Added (Phase 2 examples)

19 example apps under `examples/` covering the full (SDK × backend)
matrix:

- **Web/Node**: `web-vanilla-cdn`, `node-llama-cpp` (alongside the
  pre-existing `web-react`, `node-langchain`).
- **iOS native**: `ios-llama`, `ios-foundation`, `ios-coreml`, `ios-mlx`.
- **Android native**: `android-llama`, `android-mediapipe`, `android-litert`.
- **Hybrid**: `capacitor-mobile`, `react-native-app`, `flutter-app`.
- **.NET**: `dotnet-maui`, `dotnet-desktop-llama`, `dotnet-desktop-onnx`,
  `dotnet-desktop-mlnet`.
- `examples/MATRIX.md` — full SDK × backend matrix with host requirements + demo-flow paths.
- `scripts/demos/*.yaml` — per-example demo flows.
- `scripts/mac-side-build-examples.sh` — batched Mac SSH driver for the iOS examples.

All examples build clean on the host that supports them (Windows for
.NET / Web / Android / Flutter; Mac for iOS via SSH); each ships a
`smoke.sh` that exits 0.

### Distribution

- All 36 dvai-bridge packages bump 2.4.1 → 2.4.2 in lockstep via
  `scripts/sync-versions.js`. **No registry publishes happen as part
  of v2.4.2** — patch is git-tag-only; npm / Maven / NuGet / pub.dev
  versions stay at 2.4.0 until the user runs the publish flow per
  PUBLISHING.md.

### No breaking changes

Pure patch release. Migration not required.

---

## [2.4.1] — 2026-04-27

Phase 3H — end-of-Phase-3 polish. Documentation, build tooling, demo
automation, launch playbook, and a substantially rewritten research
paper. **No code changes; no consumer-visible API surface change.**
Patch-bumped so the repo, packages, and research paper share one
citeable version.

### Added

- **`CONTRIBUTING.md`** at repo root — PR flow, commit conventions,
  per-SDK contributor pointers, license + copyright stance.
- **`docs/development/contributing-{ios,android,react-native,flutter,dotnet}.md`**
  — five new per-SDK contributor pages: prerequisites, build + test
  loop, common breakage modes, cross-links to user-facing guides and
  cross-cutting dev pages.
- **Per-platform build scripts** under `scripts/`:
  - `build-web.sh`, `build-ios.sh`, `build-android.sh`,
    `build-react-native.sh`, `build-flutter.sh`, `build-dotnet.sh`
    — single-purpose helpers per slice.
  - `build-all.sh` + `build-all.ps1` — orchestrator. Auto-detects
    host (Mac / Linux / Windows ± WSL) and runs only the slices that
    work there. `--fail-fast` for CI; otherwise prints per-slice
    summary.
- **Demo-recording automation**:
  - `scripts/record-demo.sh` (Bash) + `scripts/record-demo.ps1`
    (PowerShell) wrap `ffmpeg` around a YAML scene-list schema.
  - `scripts/demos/` — 7 per-SDK YAML flow files (Web React,
    Capacitor, iOS, Android, RN, Flutter, .NET MAUI) + schema
    `README.md`.
  - `--dry-run` parses + prints the scene timeline without invoking
    `ffmpeg`.
- **GitHub Pages docs deployment**:
  - `.github/workflows/deploy-docs.yml` — VitePress build +
    `actions/deploy-pages@v4`. Triggers on push to main when
    `docs/**`, `README.md`, or `CHANGELOG.md` changes.
  - `docs/public/CNAME` → `dvai-bridge.deepvoiceai.co`. DNS + Pages
    settings + cert flow documented in private `PUBLISHING.md`.
- **`RESEARCH.md` figure 6** — `paper-assets/fig6-platform-coverage.svg`
  — 7 SDK rows × 10 backend columns lattice diagram. Embedded in
  §3.2 and the regenerated PDF.

### Changed

- **`README.md`** —
  - Supported-platforms table now lists all 6 SDKs with correct
    package coordinates (RN + Flutter rows added; .NET row's NuGet
    ID corrected to `co.deepvoiceai.dvai-bridge*`; Android registry
    corrected from "Maven Central" to "GitHub Packages Maven").
  - Removed misleading "RN/Flutter coming soon" paragraph.
  - iOS install snippet repo URL fixed (`dvai-bridge-swift` →
    `dvai-bridge`); install snippets bumped from `1.0.0` examples to
    `2.4.0+`.
  - Added Flutter + RN install snippets and usage examples; rewrote
    .NET example to use the actual `DVAIBridge.Shared.StartAsync(...)`
    surface.
  - Contributing section now links to `CONTRIBUTING.md` and
    `docs/development/`.
- **VitePress site** —
  - Hero tagline + `description` + features list expanded to the
    6-SDK story.
  - `docs/guide/introduction.md` "MOAT" list now names Flutter and
    .NET (mobile + desktop) explicitly.
  - `docs/guide/comparison.md` "When you should NOT use" line about
    Flutter being "in flight" replaced with the actual constraint
    (RN ≤ 0.73 + Bridgeless OFF).
  - Sidebar gains a "Contributing" section.
- **`RESEARCH.md`** —
  - Abstract extended for 6 SDKs + 9 backends.
  - §3.2 driver table 3 → 12 rows (family-grouped).
  - §3.5 wrapper section extended with the SDK family lineage.
  - 5 new case studies (§6.6 iOS / §6.7 Android / §6.8 RN / §6.9
    Flutter / §6.10 .NET MAUI on Catalyst).
  - New §8.0 "Shipped since v1" recap; §8.1 roadmap slimmed to
    genuinely-unfinished items (`/v1/audio/*`, `/v1/images/*`,
    signed-token license, published benchmarks).
  - §9 limitations refreshed (>300 tests across the family;
    desktop is now first-class; MLC parking added).
  - References extended for Apple Foundation Models, MLX, MediaPipe
    LLM, LiteRT, ML.NET, ONNX Runtime GenAI, Microsoft.SemanticKernel,
    Pigeon, RN TurboModules.
- **`packages/dvai-bridge-dotnet/global.json`** SDK pin bumped from
  `10.0.100` to `10.0.203` (matches the documented contributor floor;
  `rollForward: latestFeature` continues to allow newer feature bands).

### Distribution

- All 36 dvai-bridge packages bump 2.4.0 → 2.4.1 in lockstep via
  `scripts/sync-versions.js`. **No registry publishes happen as part
  of v2.4.1** — patch is git-tag-only; npm / Maven / NuGet / pub.dev
  versions stay at 2.4.0 until the user runs the publish flow per
  `PUBLISHING.md`.

### No breaking changes

No API surface changes; no migration guide needed.

---

## [2.4.0] — 2026-04-27

Phase 3G — `.NET` NuGet family ships. Wraps the iOS + Android SDKs for
.NET MAUI / Avalonia / WinUI / Xamarin consumers, **plus** ships
desktop-only and .NET-specific backends so Windows / macOS / Linux .NET
hosts get full coverage instead of platform-not-supported stubs.
Mobile + desktop now share one OpenAI-compatible HTTP surface and one
`DVAIBridge.Shared` core. All other dvai-bridge packages get a
coordinated minor bump for build-graph alignment (no source changes
outside the new .NET tree).

### Added

- **`DVAIBridge.Shared` (NuGet, `co.deepvoiceai.dvai-bridge`)** — public
  facade `DVAIBridge` (singleton-style static class), `BackendKind` enum
  (9 values: `Auto` / `Llama` / `Foundation` / `CoreML` / `MLX` /
  `MediaPipe` / `LiteRT` / `Onnx` / `MLNet`), `DVAIBridgeOptions`,
  `DVAIBridgeState`, multi-consumer `ProgressBroadcaster` (per-subscriber
  bounded channels with `BoundedChannelFullMode.DropOldest`),
  `INativeBridge` abstraction, `PlatformBridgeFactory` runtime selector,
  and `UnsupportedPlatformBridge` last-resort stub.
- **`DVAIBridge.iOS`** (TFMs `net10.0-ios26.2;net10.0-maccatalyst26.2`)
  — ObjC binding shims wrapping `DVAIBridge ~> 2.3` Swift actor.
  Mac Catalyst lights up native bridging on macOS the same as iOS.
- **`DVAIBridge.Android`** (TFM `net10.0-android36.0`) — JNI/AndroidJavaObject
  shims for `co.deepvoiceai:dvai-bridge:$dvaiBridgeVersion` from GitHub
  Packages Maven (Phase 3D umbrella).
- **`DVAIBridge.Desktop`** (TFM `net10.0`, RIDs `win-x64` / `linux-x64` /
  `osx-arm64`) — first-class llama.cpp backend for Windows / Linux /
  macOS .NET hosts. P/Invoke (`DllImport`) into prebuilt
  `llama.cpp` release `b8946` binaries fetched + checksum-verified by
  `scripts/fetch-llama-binaries.sh` + `scripts/verify-llama-checksums.sh`.
  Embeds the same Kestrel OpenAI-compatible HTTP server as iOS / Android.
- **`DVAIBridge.OnnxRuntime`** (TFM `net10.0`) — ONNX Runtime backend
  via `Microsoft.ML.OnnxRuntime 1.25.0` + `Microsoft.ML.OnnxRuntimeGenAI 0.13.1`.
  `OnnxGenAIRunner` handles tokenizer + sampler + KV-cache; routed via
  `OnnxNativeBridge` and the shared Kestrel server. Targets the .NET
  ecosystem's most portable model format (CPU / CUDA / DirectML /
  CoreML EPs).
- **`DVAIBridge.MLNet`** (TFM `net10.0`) — `Microsoft.ML 5.0.0` (ML.NET)
  backend with `OnnxScoringEstimator` for classification / regression
  workloads. `MLNetInferenceEngine` + `MLNetNativeBridge`; same shared
  Kestrel surface. Caters to the "I have an ML.NET model already, give
  me the same DVAIBridge HTTP API on top of it" use case.
- **Shared Kestrel server** (`packages/dvai-bridge-dotnet/src/shared/DVAIBridge.Shared.Hosting/`)
  — three files (`IInferenceEngine.cs`, `OpenAIServer.cs`,
  `PortPicker.cs`) consumed by Desktop, ONNX, and MLNet backends so
  every .NET-side backend exposes the **same** OpenAI-compatible
  `/v1/chat/completions` (streaming + non-streaming) endpoint as the
  iOS / Android wrappers.
- **`scripts/sync-versions.js`** picks up `Directory.Build.props`
  (`<Version>` element) so the .NET family stays in lockstep with the
  rest of the monorepo via the existing root-`package.json`-version flow.
- **Docs** —
  - `docs/guide/dotnet-sdk.md` (~445 lines): 6-package install matrix,
    9-row `BackendKind` decision matrix, ONNX-vs-MLNet trade-off
    section, decision tree.
  - `docs/migration/v2.3-to-v2.4.md`: additive scope (no breaking
    changes for non-.NET consumers); covers Desktop slice, Mac Catalyst
    TPV `26.2` rationale (`.NET 10` SDK 10.0.203 ships `26.0`/`26.2`
    only — no `18.0`), ONNX Runtime install, ML.NET install, broadcaster
    cancellation fix.
- **CI** — `.github/workflows/test-dotnet.yml` runs Windows + macOS
  matrix (`dotnet test` for `DVAIBridge`, `DVAIBridge.Desktop`,
  `DVAIBridge.OnnxRuntime`, `DVAIBridge.MLNet`); host-gated tests for
  `DVAIBridge.iOS` (Catalyst on macOS) and `DVAIBridge.Android` (Windows
  + macOS). Tag-gated `dotnet pack --include-symbols` validates
  pre-release artifacts.

### Changed

- All Android module versions bumped 2.3.0 → 2.4.0 via the
  `dvaiBridgeVersion` Gradle property (5 cores + RN bridge + Flutter
  bridge = 7 modules, no source changes).
- `@dvai-bridge/android` umbrella republishes at 2.4.0 (build-graph
  alignment with the .NET wrappers' `dvai-bridge:$dvaiBridgeVersion`
  consumption).
- All other `@dvai-bridge/*` npm packages bump to 2.4.0 in lockstep via
  `scripts/sync-versions.js`.
- **`ProgressBroadcaster` cancellation fix** — `MoveNextAsync` now
  yield-breaks on `OperationCanceledException` when the per-subscriber
  cancellation token is signalled, instead of letting it bubble out as
  an unhandled exception. Internal-only; consumer surface unchanged.

### Distribution asymmetry (new with 3G)

`co.deepvoiceai.dvai-bridge.*` is the **first** family member published
to **public NuGet.org**. Other family members continue on private
GitHub Packages npm + Maven; Flutter remains on public pub.dev (Phase
3F). See `PUBLISHING.md` §"NuGet — `.NET` family (Phase 3G)" for the
publish flow.

### Pinned dependency versions (verified 2026-04-27)

| Tool | Pin |
|---|---|
| `dotnet` SDK floor | `10.0.203` (LTS) |
| `Microsoft.ML.OnnxRuntime` | `1.25.0` |
| `Microsoft.ML.OnnxRuntimeGenAI` | `0.13.1` |
| `Microsoft.ML` | `5.0.0` |
| iOS / Catalyst TPV | `26.2` (the only mobile TPVs `.NET 10` SDK 10.0.203 ships — `18.0` is `.NET 9`) |
| Android TPV | `36.0` |
| llama.cpp binaries | release tag `b8946` |

### Known follow-ups after 2.4.0

- **Docs / launch polish** (Phase 3H) — public-facing v2.x release
  story, sample-app scripts, marketing pages. Active next.
- **MLC LLM backend** — still *parked* (see 2.3.0 entry + research
  doc). Not on active backlog.

---

## [2.3.0] — 2026-04-27

Phase 3F — Flutter plugin ships. The Flutter side wraps the v2.2 iOS
DVAIBridge SDK + v2.2 Android DVAIBridge SDK behind a Pigeon-generated
type-safe Dart API, mirroring the Phase 3E React Native module's role
for Flutter consumers. All other dvai-bridge packages get a coordinated
patch bump for build-graph alignment (no source changes outside the
new Flutter package).

### Added

- **`dvai_bridge` (Flutter plugin, `@dvai-bridge/flutter`)** — unified
  plugin (single package, not federated). Public Dart facade
  (`DVAIBridge` singleton) with the same 4-method lifecycle API as the
  iOS / Android / RN packages: `start`, `stop`, `status`,
  `downloadModel`. Cross-platform `BackendKind` Dart enum is the union
  of every iOS + Android backend (`auto` / `llama` / `foundation` /
  `coreml` / `mlx` / `mediapipe` / `litert`); the Dart facade
  pre-validates against `Platform.isIOS` / `Platform.isAndroid` and
  throws `DVAIBridgeError.backendUnavailable` before crossing the
  Pigeon channel.
- **Pigeon-generated platform channels** — `@HostApi()` for the four
  lifecycle methods + `@EventChannelApi()` for the progress event
  stream. Type-safe Dart ↔ Swift ↔ Kotlin bindings; codegen output
  (`messages.g.dart`, `Messages.g.swift`, `Messages.g.kt`) is
  gitignored and regenerated by CI before each test run.
- **`Stream<DVAIBridgeState>` reactive surface** — composable with
  `StreamBuilder`, Riverpod `StreamProvider`, and Bloc. First-listener
  bootstrap fetches `status()`; subsequent transitions are derived
  from the progress event stream (`completed`+`start` → ready,
  `completed`+`stop` → idle, `failed`+`start` → lastError).
- **iOS Swift bridge** — `dvai_bridge.podspec` depends on
  `DVAIBridge ~> 2.2` (resolves 2.3.x patches cleanly).
  `DVAIBridgeFlutterPlugin.swift` wraps `DVAIBridge.shared` await calls
  in `Task { ... }` (Pigeon 26 doesn't yet generate Swift `actor`
  return types; documented as a known limitation in the spec).
- **Android Kotlin bridge** — depends on
  `co.deepvoiceai:dvai-bridge:$dvaiBridgeVersion` from GitHub Packages
  Maven. `DVAIBridgeFlutterPlugin.kt` bridges Pigeon's non-suspending
  callback shape to Kotlin coroutines on `Dispatchers.IO`.
- **Docs** — new `docs/guide/flutter-sdk.md` (mirrors the iOS / Android
  / RN guides). VitePress sidebar adds Flutter SDK entry. Migration
  guide [`docs/migration/v2.2-to-v2.3.md`](docs/migration/v2.2-to-v2.3.md)
  covers the additive scope (no breaking changes for non-Flutter
  consumers).
- **CI** — `.github/workflows/test-flutter.yml` runs Pigeon codegen +
  `flutter analyze` + `flutter test` on Linux. Matrix: Flutter 3.41.5
  + 3.39.4. Tag-gated `dart pub publish --dry-run` validates pre-release.

### Changed

- All Android module versions bumped 2.2.0 → 2.3.0 via the
  `dvaiBridgeVersion` Gradle property in each module's
  `gradle.properties` (5 cores + RN bridge + new Flutter bridge =
  7 modules).
- `@dvai-bridge/android` umbrella republishes at 2.3.0 (no source
  changes; build-graph alignment with the Flutter plugin's
  `dvaiBridgeVersion` consumption — Phase 3F Plan Task 8).
- All other `@dvai-bridge/*` npm packages bump to 2.3.0 in lockstep
  via `scripts/sync-versions.js`.

### Distribution asymmetry (new with 3F)

`dvai_bridge` is the **first** family member published to **public
pub.dev** (Flutter has no good private-pub equivalent). All other
family members continue on private GitHub Packages npm + Maven. See
`PUBLISHING.md` §"pub.dev — dvai_bridge (Phase 3F)" for the publish
flow.

### Pinned dependency versions (verified 2026-04-27)

| Tool | Pin |
|---|---|
| `flutter` (consumer floor) | `>=3.39.0` |
| `dart` (consumer floor) | `>=3.7.0 <4.0.0` |
| Pigeon (dev) | `^26.3.4` |
| AGP (Flutter plugin module) | `8.7.3` (Flutter 3.41 plugin tooling not yet AGP-9 ready; consumer apps can still use 9.x via the underlying umbrella AAR) |
| Kotlin / JVM target | 2.3.21 / 17 (matches Phase 3D umbrella) |
| iOS deployment target | 15.1 (matches Phase 3C) |

### Known follow-ups after 2.3.0

- **`.NET NuGet package`** (Phase 3G) — wraps the iOS + Android SDKs
  for MAUI / Avalonia / Xamarin consumers. Active next.
- **Docs / launch polish** (Phase 3H) — public-facing v2.x release
  story, sample-app scripts, marketing pages. Follows 3G.
- **MLC LLM backend** — *parked* after the 2026-04-27 build-chain
  spike. See `docs/research/2026-04-27-mlc-llm-backend-feasibility.md`
  for the parking decision and re-examination triggers (stable MLC
  release channel, validated perf claim from a real consumer, or a
  workload MediaPipe + LiteRT can't serve). Not on the active
  backlog until a trigger fires.

---

## [2.2.0] — 2026-04-27

Phase 3E — React Native module ships. The RN side wraps the v2.1 iOS
DVAIBridge SDK + v2.1 Android DVAIBridge SDK behind a TurboModule so
RN ≥ 0.85 (Bridgeless ON) consumers can drop `@dvai-bridge/react-native`
into their app and call `DVAIBridge.start(...)` from JS / TS.

### Added

- **`@dvai-bridge/react-native`** — TurboModule that surfaces the same
  8-method DVAIBridge API to JS. Cross-platform `BackendKind` is the
  union of every iOS + Android backend (`auto` / `llama` / `foundation`
  / `coreml` / `mlx` / `mediapipe` / `litert`); the TS facade
  pre-validates against `Platform.OS` and throws `backendUnavailable`
  for wrong-platform selections without crossing the bridge.
- **`useDVAIBridgeState()`** React hook — subscribes to native progress
  events via `NativeEventEmitter` (Combine on iOS, `Flow` on Android)
  and re-fetches `status()` on terminal events. Returns
  `{ isReady, baseUrl, port, backend, modelId, lastProgress }` ready
  to render in a Compose-style React tree.
- **iOS bridge** — `DVAIBridgeNative.podspec` with
  `s.dependency 'DVAIBridge'`; `ios/DVAIBridgeNative.{h,mm,swift}`
  forwards JS calls to `DVAIBridge.shared` and maps
  `ProgressEvent.Phase` to JS-side `{ kind, phase, percent, message }`
  discriminators.
- **Android bridge** — Kotlin module that calls
  `co.deepvoiceai.bridge.DVAIBridge`; depends on
  `co.deepvoiceai:dvai-bridge:2.2.0` via the consumer's GitHub Packages
  Maven setup. Dual old-arch + new-arch source sets selected by
  `newArchEnabled` so RN ≤ 0.74 → 0.85 mid-migration consumers link
  cleanly.
- **CI workflow** (`.github/workflows/test-react-native.yml`) — runs
  `bob build` + Jest on Linux. iOS pod-lint and Android Gradle
  full-build aren't part of the CI matrix (no host consumer app to
  exercise autolinking); Mac developers verify manually before
  publishing.
- **Docs** — `docs/guide/react-native-sdk.md` mirroring the iOS / Android
  guides; install via npm + GitHub Packages, Quickstart, BackendKind +
  platform availability table, `useDVAIBridgeState` example, errors
  reference, MLX-under-CocoaPods caveat, Bridgeless requirement.

### Changed

- All Android module versions bumped 2.1.0 → 2.2.0 via the
  `dvaiBridgeVersion` Gradle property in each module's
  `gradle.properties`. The `$dvaiBridgeVersion` interpolation in each
  module's `build.gradle` cross-package dep declarations means future
  bumps continue to require touching only the root `package.json`.

### Pinned dependency versions (verified 2026-04-27)

| Tool | Pin |
|---|---|
| `react-native` (peer) | `>=0.77.0 <1.0.0` (CI uses 0.85.2) |
| `react-native-builder-bob` | 0.41.0 |
| `typescript` | 6.0.3 |
| `react` (peer) | `>=18.0.0` |
| Jest | 30.x |
| AGP / Kotlin / JVM | 9.2.0 / 2.3.21 / 17 |

### Known Phase 3F follow-ups

- **Flutter package** — wraps the iOS + Android SDKs via Flutter's
  platform channels. Phase 3F.
- **Expo plugin** — config-plugin auto-injecting the native deps for
  Expo prebuild consumers. Phase 3H.

---

## [2.1.0] — 2026-04-27

Phase 3D — Android Native SDK ships. The Android side now mirrors the iOS
SDK shape: a single umbrella `co.deepvoiceai:dvai-bridge` AAR wraps the
existing llama / MediaPipe cores plus a new bare-LiteRT backend behind a
unified `DVAIBridge` Kotlin singleton.

### Added

- **`@dvai-bridge/android` umbrella package** — `co.deepvoiceai:dvai-bridge`
  AAR. Public `DVAIBridge` Kotlin object with the same 8-method surface
  as the iOS SDK (`init`, `start`, `stop`, `status`, `downloadModel`,
  `addProgressListener`, `removeProgressListener`, plus `progressFlow` /
  `reactive` properties). `BackendKind` enum (`Auto` / `Llama` /
  `MediaPipe` / `LiteRT`) with file-extension-based auto-resolution.
  `DVAIBridgeReactiveState` exposes `StateFlow<*>` for Compose / Lifecycle
  integration. See [Android Native SDK guide](docs/guide/android-native-sdk.md).
- **`@dvai-bridge/android-litert-core`** — new bare-LiteRT backend
  (distinct from the bundled-task MediaPipe wrapper). Pinned
  `com.google.ai.edge.litert:litert:2.1.4`; the LiteRT-LM helper artifact
  doesn't exist standalone, so token-by-token decoding runs directly on
  `CompiledModel` with named tensors (`input_ids`, `causal_mask`, `logits`).
  Tokenization: pure-Kotlin `tokenizer.json` BPE parser (no JNI dep —
  HF's `tokenizers-android` JitPack guess does not exist; DJL's
  HuggingFace tokenizer ships no Android `.so`). Chat templates: built-in
  LLAMA3 + PLAIN renderers; SentencePiece / Unigram tokenizers reject at
  load time (use the MediaPipe backend for Gemma).
- **`@dvai-bridge/android-shared-core`** — extracted `HttpServer` +
  `HandlerDispatch` + `HandlerContext` + `DvaiHandlers` + `HandlerResponse`
  + `CorsConfig` (with new `CorsConfig.fromOpt` companion) out of
  `android-llama-core` and `android-mediapipe-core` into a dedicated
  module. Each core now declares `api 'co.deepvoiceai:android-shared-core'`
  so consumers see the moved types transitively. Mirrors the iOS Phase 3C
  DVAISharedCore extraction.
- **`scripts/android-publish-local.sh`** — orders + invokes
  `publishToMavenLocal` across all 5 Android packages in dep order. Auto-
  detects JDK 21+ (Robolectric @ compileSdk 36 requires it) from a
  Homebrew openjdk install or Android Studio's bundled JBR.
- **CI workflows re-enabled** — `.github/workflows/*.yml.disabled` are
  back to `.yml`. New per-module workflows for shared-core and litert-core;
  the existing llama / mediapipe workflows now seed shared-core to
  mavenLocal before running their tests. New umbrella workflow runs the
  reflection-based API-shape + selector + progress-broadcaster unit tests
  after publishing all 4 cores to mavenLocal.

### Changed

- **Both pre-existing Android cores** declare
  `implementation 'co.deepvoiceai:android-shared-core' → api ...`. Direct
  consumers of `@dvai-bridge/android-llama-core` or
  `@dvai-bridge/android-mediapipe-core` need to add
  `import co.deepvoiceai.bridge.shared.core.*` for the moved types — see
  the [migration guide](docs/migration/v1.6-to-v2.0.md).
- **All Android module versions** are now driven by
  `dvaiBridgeVersion` in each module's `gradle.properties`, propagated
  by `scripts/sync-versions.js` from the root `package.json`. Future
  bumps touch one file (root package.json) instead of five build.gradle
  files.

### Documentation

- New `docs/guide/android-native-sdk.md` — installation (GitHub Packages
  Maven), Quickstart, BackendKind table + auto-resolution rules, Compose
  reactive state, progress events, errors, backend-specific notes.
- VitePress sidebar adds the Android Native SDK page next to the iOS one.
- Migration guide updated with the Kotlin-side import surface change.

### Known Phase 3E follow-ups

- **React Native module** (`@dvai-bridge/react-native`) — wraps the iOS +
  Android native SDKs via React Native's bridging. Phase 3E.
- **Flutter package** — same as RN, via Flutter's platform channels. Phase 3F.

---

## [2.0.0] — 2026-04-27

First tagged release after `v1.6.0`. The previously-shown `[1.7.0]` and
`[1.8.0]` sections below were CHANGELOG-only — they were never tagged
on GitHub. Their content (Phase 3A core extraction + Phase 3B LiteRT-LM
migration + Phase 3C iOS Native SDK) is included in this release;
read those sections for the per-sub-phase breakdown. **For migration,
see [v1.6 → v2.0](docs/migration/v1.6-to-v2.0.md).**

> **Versioning policy going forward**: version bumps and git tags
> happen at *whole-phase* boundaries (Phase 3 = 3A + 3B + 3C + 3D
> combined), not per sub-phase. Tag-first, then CHANGELOG entry.

### Added (since v1.6.0)

Everything documented in `[1.7.0]` and `[1.8.0]` below, **plus**:

- **`@dvai-bridge/ios-shared-core` package** — extracts `HandlerContext`
  / `HandlerResponse` / `DVAIHandlers` / `CORSConfig` / `dispatchRoute`
  / `formatResponse` / `HttpServer` out of `DVAILlamaCore` so non-llama
  backends (foundation / coreml / mlx) don't transitively pull
  `llama.xcframework`. Foundation-core's previously-duplicated copies
  of these files are deleted; the previous `FoundationHttpServer`
  rename (introduced for CocoaPods name-collision avoidance) is also
  reverted now that the canonical `HttpServer` lives in shared-core.
  This is an internal refactor: the public DVAIBridge API surface is
  unchanged, but direct consumers of `@dvai-bridge/ios-llama-core`
  must add `import DVAISharedCore` for the moved types — see the
  [migration guide](docs/migration/v1.6-to-v2.0.md).

- **MLX backend (4th iOS backend)** — new `@dvai-bridge/ios-mlx-core`
  package wrapping [`mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm)
  for Apple-Silicon GPU + Neural Engine LLM inference. Loads MLX-converted
  HuggingFace checkpoints via `loadModelContainer(id:)` (HF Hub-cached,
  e.g. `mlx-community/Llama-3.2-1B-Instruct-4bit`). iOS 17+ / macOS 14+
  at link time; Apple-Silicon-only at runtime.
  - `BackendKind.mlx` + `BackendInstance.mlx` cases wired into DVAIBridge.
  - SwiftPM-only — `mlx-swift-lm`'s transitive Swift packages don't
    publish CocoaPods specs, so selecting `.mlx` under a CocoaPods build
    throws `DVAIBridgeError.backendUnavailable` with a clear message.
- **`@dvai-bridge/capacitor-mlx`** Capacitor plugin mirroring the
  `capacitor-foundation` pattern — installs a `DVAIBridgeMLX` native
  plugin that forwards to `MLXPluginState`. The umbrella
  `@dvai-bridge/capacitor` shim's `CapacitorBackend` type-union now
  includes `"mlx"`. Android selecting `.mlx` returns the same `iOS-only`
  error as `.foundation`.
- **CoreML integration test infrastructure** — rewrote the test to
  download the `.mlmodelc/` directory file-by-file from a public HF
  mirror (`finnvoorhees/coreml-Llama-3.2-1B-Instruct-4bit`) rather
  than zip-and-unzip, so the iOS Simulator's lack of `Process` is no
  longer a blocker. The public mirror also bundles `tokenizer.json` +
  `tokenizer_config.json`, so the gated meta-llama repo +
  `SMOKE_HF_TOKEN` are no longer required.
  - Single env var: `SMOKE_COREML_MODEL_BASE_URL`. The old four
    `SMOKE_COREML_*` + `SMOKE_HF_TOKEN` vars are no longer needed.
  - The test itself is currently **gated off** (XCTSkip) — see the
    "CoreML backend — IRValue crash at first prediction" follow-up
    in §"Known Phase 3D follow-ups" below. Re-enabling is a one-line
    change once the IRValue cause is understood.

### Documentation

- New `docs/guide/ios-native-sdk.md` — installation (SwiftPM + CocoaPods),
  basic usage, BackendKind selection, ReactiveState SwiftUI integration,
  CocoaPods asymmetries.
- New `docs/guide/mlx-backend.md` — MLX-specific usage (HF model ids,
  Apple-Silicon constraint, embeddings-not-supported caveat, model
  conversion pointers).
- `docs/guide/native-backend.md` updated to show the 5-package
  architecture (capacitor + 4 backends) and the `capacitor-mlx`
  platform table row.
- VitePress sidebar adds the iOS Native SDK + MLX backend pages.

### Known Phase 3D follow-ups

- **Mac Catalyst destination support per backend.** llama.cpp's
  `build-xcframework.sh` doesn't produce a Catalyst slice, so the
  llama backend can't run on Catalyst without forking the upstream
  build script. With the shared-core extraction landed (above),
  MLX / Foundation Models / CoreML no longer transitively need
  `llama.xcframework` — those backends can run on Catalyst as soon as
  the consumer's app target requests it. Concrete Catalyst test
  destination wiring is deferred until a Catalyst consumer surfaces.
- **CoreML backend — IRValue crash at first prediction.** The
  `CoreMLGenerator` `causal_mask` wiring (and KV-cache position
  tracking) is now in place and matches Apple's published shape
  conventions. `MLModel` load + tokenizer load + bridge boot all
  succeed on macOS-native. However, the first
  `model.prediction(from:using:)` call against
  `finnvoorhees/coreml-Llama-3.2-1B-Instruct-4bit` crashes hard
  inside CoreML's C++ IR layer with *"Cannot retrieve vector from
  IRValue format int32"*. The crash is a process exit, not a
  catchable Swift error; it reproduces on **both** iOS Simulator and
  macOS-native. The `RealModelIntegrationTest.testCoreMLBackendIntegration`
  is gated off via `XCTSkip` until the cause is understood — live
  debug on a real iOS device with Instruments is the next step.
  Other backends (llama / foundation / mlx) are unaffected. Tracking
  comments live in `CoreMLEngine.swift` (the `runStep` doc) and the
  test method itself.

---

## [1.8.0] — 2026-04-27 *(CHANGELOG-only; never tagged)*

Phase 3C — iOS Native SDK: standalone `@dvai-bridge/ios` package wrapping
`DVAILlamaCore` + `DVAIFoundationCore` + a fully-implemented
`DVAICoreMLCore`. First non-Capacitor consumer surface for the
OpenAI-compatible HTTP server on iOS, with three production-quality
backends.

### Added

- `@dvai-bridge/ios` npm package with SPM `Package.swift` at the package
  root and a `DVAIBridge.podspec` for CocoaPods consumers.
- `DVAIBridge.shared` singleton actor exposing the 8-method public API:
  `start`, `stop`, `status`, `addProgressListener`, `downloadModel`,
  `listCachedModels`, `deleteCachedModel`, `cacheDir`.
- `BackendKind` enum (`.auto`, `.llama`, `.foundation`, `.coreml`) with
  `auto`-resolution at runtime based on modelPath extension + iOS 26+
  availability.
- `DVAIBridgeReactiveState` `@MainActor` `ObservableObject` for SwiftUI
  consumers — `isReady`, `baseUrl`, `port`, `currentBackend`,
  `lastProgress` published properties wired to the bridge's lifecycle
  + progress events via a per-instance registry.
- Three observation surfaces for `ProgressEvent`: Combine
  `progressPublisher`, `progressStream` (`AsyncStream`), and
  `addProgressListener(_:)` callback. All three observe the same source.
- **Full CoreML LLM backend** (`DVAICoreMLCore`):
  - `MLModel` + `MLState` for KV-cached autoregressive decoding
    (iOS 18+ / macOS 15+).
  - `swift-transformers` 1.3.0 (HuggingFace) for tokenization +
    `applyChatTemplate(...)` across Llama / Gemma / Phi families.
  - Greedy + temperature + top-p + top-k sampling.
  - Streaming via SSE (`AsyncStream<String>` produced by
    `CoreMLGenerator.generateStream(...)`).
  - OpenAI ChatCompletion / Completion / Models JSON output via
    `CoreMLHandlers`, served on Telegraph with the same port-fallback
    + CORS plumbing as the llama core.
  - Reference checkpoint: `apple/coreml-Llama-3.2-1B-Instruct-4bit`
    (others should work if the input/output tensor names match).
- `RealModelIntegrationTest` — three end-to-end tests against real models,
  one per backend, gated on env-var availability:
  - `testLlamaBackendIntegration` (uses Phase 2C's existing
    `SMOKE_MODEL_*` env vars; verified passing on iOS Simulator with
    Llama-3.2-1B Q4_K_M).
  - `testFoundationBackendIntegration` (iOS 26+ runtime; no model file).
  - `testCoreMLBackendIntegration` (new `SMOKE_COREML_*` env vars +
    `SMOKE_HF_TOKEN` for the gated meta-llama tokenizer; the unzip step
    requires `Process` so the iOS-Simulator path skips with a Phase 3D
    follow-up note — exercise via Mac Catalyst destination, or land an
    in-process unzip).
- `test-ios-bridge.yml` CI workflow running XCTest for the
  `DVAIBridge-Package` scheme on the self-hosted Mac runner.
- Public `DVAIHandlers` protocol + `HandlerContext` + `HandlerResponse` +
  `HttpServer.tryBind(...)` / `installRoutes(...)` exposed from
  `DVAILlamaCore` (surgical visibility bumps; no logic changes).
- `ModelDownloader.DownloadError` exposed as `public` so cross-module
  consumers (DVAIBridge) can pattern-match `.checksumMismatch` instead
  of grepping the localized error string.

### CocoaPods packaging

- **`pod lib lint DVAIBridge.podspec` — passes** on Xcode 26 / iOS 26 SDK.
  The podspec is now a single-target spec that mirrors our SwiftPM module
  graph by vendoring the upstream HuggingFace stack and gating
  cross-target imports behind `#if !COCOAPODS`.
- Vendored under `packages/dvai-bridge-ios/Vendor/swift-transformers/`
  (gitignored only at the level of build output, but source tree is
  checked in):
  - `huggingface/swift-transformers @ 1.3.0` — `Tokenizers` + `Hub`
    (the upstream `Hub/HubApi.swift` is replaced by a stripped 80-line
    variant that drops Crypto / HuggingFace / yyjson / EventSource /
    swift-xet / swift-crypto code paths we never call. JSON parsing
    backed by `Foundation.JSONSerialization`).
  - `huggingface/swift-jinja @ 2.3.5`.
  - `apple/swift-collections @ 1.4.1` — `OrderedCollections` +
    `InternalCollectionsUtilities`.
  - Apache-2.0 LICENSE preserved as
    `Vendor/swift-transformers/LICENSE-<dep>`.
- New helper scripts:
  - `scripts/wrap-cocoapods-imports.py` — idempotent post-vendor pass
    that wraps every cross-target `import` with `#if !COCOAPODS` so the
    same source tree compiles cleanly under both SwiftPM (which pulls
    the real upstream packages) and CocoaPods (which collapses the pod
    into a single `DVAIBridge` Swift module).
  - `scripts/patch-cocoapods-vendor.py` — idempotent patches that
    rename collisions (Tokenizers' `Decoder` → `TokenizerStepDecoder`,
    Jinja's `Value` → `JinjaValue`) so the flattened CocoaPods module
    has no shadowing.
- `mac-side-prepare-xcframework.sh` is unchanged; the podspec uses a
  `prepare_command` that copies the built `llama.xcframework` /
  `mtmd.xcframework` and the sibling-package source dirs into a
  pod-local `Frameworks/` and `Sources/_external/` so CocoaPods'
  globbing (which doesn't follow `..` paths) can find them.

### CocoaPods vs SwiftPM asymmetries (intentional)

The two distribution channels are not symmetric. SwiftPM remains the
primary path; CocoaPods is a best-effort wrapper for shops on that
toolchain.

- **`DVAIBridgeReactiveState` is not an `ObservableObject` under
  CocoaPods.** Xcode 26 / iOS 26 SDK's static linker emits an implicit
  link directive for `SwiftUICore` (a private framework non-Apple
  products cannot link) for any module that conforms a type to
  `ObservableObject`, even if the module never imports SwiftUI.
  CocoaPods bundles the whole pod into one Swift module, so the
  trigger lands on every consumer's link line and pod lib lint /
  release builds fail with `cannot link directly with 'SwiftUICore'`.
  SwiftPM is unaffected because the ObservableObject conformance ends
  up in a library that's link-resolved at the consumer's app target,
  where SwiftUICore access *is* allowed.
  In place of the conformance + `@Published` wrappers, CocoaPods
  consumers get a `stateChanges: AnyPublisher<Void, Never>` that
  fires on every property change. Pattern:
  ```
  .onReceive(DVAIBridge.shared.reactive.stateChanges) { _ in
      // re-render off DVAIBridge.shared.reactive.<prop>
  }
  ```
  See [ReactiveState.swift](packages/dvai-bridge-ios/ios/Sources/DVAIBridge/ReactiveState.swift) for the full doc-comment rationale.
- **The Foundation Models backend is SwiftPM-only.** `import
  FoundationModels` emits implicit autolink directives for the same
  family of private frameworks (`SwiftUICore`, `UIUtilities`,
  `CoreAudioTypes`) that CocoaPods consumers cannot link.
  `BackendKind.foundation` remains in the public API for symmetry, but
  selecting it under a CocoaPods build throws
  `DVAIBridgeError.backendUnavailable(.foundation, reason: "...use
  SwiftPM if your app needs the Foundation backend...")`.
  CocoaPods consumers get `.llama` and `.coreml` which together cover
  the broad on-device-LLM use case.
- **Telegraph version differs by channel.** SwiftPM resolves Telegraph
  `0.40.0` (latest GitHub tag); CocoaPods resolves `~> 0.30` (latest
  on CocoaPods trunk — Building42 hasn't published 0.40+ to trunk).
  Our usage only touches stable core types
  (`Server` / `HTTPRequest` / `HTTPResponse` / `HTTPStatus` /
  `HTTPHeaders`) which are unchanged across the 0.30→0.40 range.

### Verified

- 44 XCTest cases pass on iOS Simulator (42 unit + 1 llama
  integration end-to-end + 1 expected skip for Foundation Models which
  needs iOS 26+ runtime).
- CoreML real-model integration test wiring is verified end-to-end —
  download, sha256 verify, unzip, tokenizer load, server start, chat
  completion — but currently SKIPS at runtime with a clear message
  because Apple removed
  `apple/coreml-Llama-3.2-1B-Instruct-4bit` from HuggingFace
  (its API now returns "Repository not found"). The test passed
  end-to-end against this exact checkpoint at the time the test was
  authored (Phase 3C development). When a replacement public
  CoreML-converted Llama-style stateful checkpoint becomes available,
  point `SMOKE_COREML_MODEL_URL`/`SMOKE_COREML_MODEL_SHA256` at it.
  Test now hard-skips with an explanatory message if the model URL
  returns 4xx, rather than failing with a confusing "sha256 mismatch"
  on the tiny error response body.
  CoreML still also skips on iOS Simulator (Process unavailable for
  unzip) and on Mac Catalyst (xcframework lacks a Mac Catalyst slice
  — Phase 3D).
- `pod lib lint DVAIBridge.podspec --allow-warnings` passes on Xcode
  26.4 / CocoaPods 1.15.2.
- Existing Capacitor tests + Phase 3A/3B test suites unaffected.

### Manual setup for the CoreML integration test (first-time only)

The CoreML backend's integration test downloads ~700 MB of model
weights + a few MB of tokenizer config. The user populates
`scripts/smoke.local.env` with:

```
SMOKE_COREML_MODEL_URL=https://huggingface.co/apple/coreml-Llama-3.2-1B-Instruct-4bit/resolve/main/StatefulModel.mlmodelc.zip
SMOKE_COREML_MODEL_SHA256=<sha256 of the zip>
SMOKE_COREML_TOKENIZER_URL=https://huggingface.co/meta-llama/Llama-3.2-1B-Instruct/resolve/main/tokenizer.json
SMOKE_COREML_TOKENIZER_SHA256=<sha256 of tokenizer.json>
SMOKE_HF_TOKEN=hf_<your-token>      # for the gated meta-llama repo
```

As of 2026-04 BOTH the Apple CoreML model
(https://huggingface.co/apple/coreml-Llama-3.2-1B-Instruct-4bit) and
the Llama-3.2 tokenizer
(https://huggingface.co/meta-llama/Llama-3.2-1B-Instruct) are gated HF
repos. The user must accept the license terms on each repo once and
create a read-only access token at
https://huggingface.co/settings/tokens. The same token is used for both
downloads.

After accepting the license and downloading the
`StatefulModel.mlmodelc.zip` once with auth, compute its sha256 with
`shasum -a 256 StatefulModel.mlmodelc.zip` and put that hash into
`SMOKE_COREML_MODEL_SHA256` (the SHA changes if Apple republishes).

## [1.7.0] — 2026-04-26 *(CHANGELOG-only; never tagged)*

Phase 3A Foundation + Phase 3B LiteRT-LM Migration: extracts each
Capacitor plugin's portable native code into separate `*-core` packages
so the same source feeds both the Capacitor wrapper and the upcoming
standalone native SDKs (iOS Swift Package Manager, Android AAR, .NET
NuGet, RN, Flutter). MediaPipe Android backend migrates from the
deprecated `tasks-genai` SDK to LiteRT-LM `0.10.2`.

### Added

- Four new `*-core` packages, each Capacitor-free and consumable
  standalone:
  - `@dvai-bridge/ios-llama-core` — pure Swift / ObjC++ llama.cpp core
    (Telegraph HTTP server, OpenAI handlers, model downloader,
    content-parts translator, ObjC++ bridge into llama.cpp + mtmd)
  - `@dvai-bridge/ios-foundation-core` — pure Swift Apple
    FoundationModels core (link-time iOS 18.1, runtime iOS 26+)
  - `@dvai-bridge/android-llama-core` — pure Kotlin + JNI llama.cpp
    core (Ktor HTTP server, NDK CMake build of llama.cpp, JNI bridge)
  - `@dvai-bridge/android-mediapipe-core` — pure Kotlin LiteRT-LM core
- 16 KB Android page-size alignment baked into the llama-core NDK build
  (`-Wl,-z,max-page-size=16384`), with a CI verification step that
  runs `objdump -p` on every produced `.so` and fails the build on
  alignment regression. Compatible with Google Play's 2025 mandate.
- CI workflows split per-package: each Android JVM workflow runs
  `core-jvm-test` then `wrapper-jvm-test` (`api project(...)` re-export
  means the wrapper transitively rebuilds the core anyway, but split
  reporting attributes test failures to the right package).
- `scripts/verify-cap-sync.sh` — end-to-end regression test that boots
  a throwaway Capacitor host app, installs all plugins + cores via
  `file:` paths, runs `npx cap sync`, and asserts both Android and iOS
  resolve cleanly against the new package layout.
- `docs/development/litert-lm-migration-notes.md` — Phase 3B inventory
  artifact with side-by-side `tasks-genai` → `litertlm-android` API
  mapping, behavioral deltas, and risk register.

### Changed

- `@dvai-bridge/capacitor-llama`, `@dvai-bridge/capacitor-foundation`,
  and `@dvai-bridge/capacitor-mediapipe` are now thin Capacitor wrappers
  that depend on their respective `*-core` packages. Host apps must
  install both the wrapper and its core(s) — the wrapper's
  `package.json` lists them as `peerDependencies` and the install
  error is actionable.
- Android Kotlin package id renamed: `co.deepvoiceai.dvaibridge.*`
  → `co.deepvoiceai.bridge.*` across the entire Android tree (drops the
  redundant "dvai" segment that's already in the org name and the npm
  package names). Core sub-packages are `co.deepvoiceai.bridge.*.core`;
  wrapper packages are `co.deepvoiceai.bridge.*`. JNI symbols
  regenerate to match (`Java_co_deepvoiceai_dvaibridge_llama_*` →
  `Java_co_deepvoiceai_bridge_llama_core_*`). Capacitor plugin IDs
  (`@CapacitorPlugin(name = "DVAIBridgeLlama")`) are unchanged.
- llama.cpp git submodule relocated from
  `packages/dvai-bridge-capacitor-llama/native/llama.cpp` to
  `packages/dvai-bridge-android-llama-core/android/src/main/cpp/native/llama.cpp`.
  iOS xcframework binary targets and `scripts/mac-side-prepare-xcframework.sh`
  follow.
- `MediaPipeBridgeApi.completePrompt` and `streamPrompt` now take
  `List<ByteArray>` instead of `List<MPImage>`, so the bridge interface
  no longer leaks MediaPipe types. Internal-only; no Capacitor / public
  JS API impact.
- `@dvai-bridge/android-mediapipe-core` migrated from
  `com.google.mediapipe:tasks-genai:0.10.33` (`@Deprecated` since
  0.10.27) and `tasks-core:0.10.33` to a single artifact
  `com.google.ai.edge.litertlm:litertlm-android:0.10.2`. Class renames:
  `LlmInference` → `Engine`, `LlmInferenceSession` → `Conversation`,
  `MPImage` → `Content.ImageBytes(ByteArray)`. The "add chunks then
  generate" call sequence becomes a single `sendMessage(Contents.of(...))`.
  Same handler behaviour; same Capacitor JS contract.
- `PluginState`'s public surface in both `android-llama-core` and
  `android-mediapipe-core` switched from Capacitor's `JSObject` to
  plain `Map<String, Any?>`. The wrapper's `Plugin.kt` translates
  `JSObject ↔ Map` at the JS-bridge boundary via small private helpers.

### Removed

- `tasks-genai` and `tasks-core` Maven dependencies.
- `MPImage` references from public bridge interfaces.
- Capacitor `JSObject` references from core packages.

### Verified

- TS suite: 104 / 104.
- iOS XCTest (full suite, real-model smoke skipped): llama-core 64,
  foundation-core 10, capacitor-llama 1, capacitor-foundation 1.
- Android JVM: llama-core 53+ (BUILD SUCCESSFUL), mediapipe-core 26,
  capacitor-llama 1, capacitor-mediapipe 2. mediapipe-core's 26 tests
  all pass against the LiteRT-LM-backed bridge implementation.

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
