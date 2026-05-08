# TODO

Long-running items that are intentionally deferred. Items here are
**not** time-pressed — they're tracked so they don't get forgotten,
not because they need to ship next. For active release-prep, see
`RELEASE-CHECKLIST.md` (when present).

> **Reminder protocol:** at the end of each milestone (each minor
> release, each completed Phase) skim this file and surface anything
> that's now ripe to pick up. Don't pre-emptively action items here
> — wait for an explicit "OK take this on" before scoping work into
> the active plan.

---

## Hub immediate post-v3.1.0

These were originally in `RELEASE-CHECKLIST.md` but consciously
descoped from v3.1.0 ship. They block the Hub becoming a "click to
install from a package manager" experience but not a "download the
binary from GitHub Release" experience, which is what v3.1.0 is.

### Distribution channels — Homebrew + winget

Hub today is install-by-download from the GitHub Release page. The
Homebrew + winget paths give the user-facing `brew install` /
`winget install` UX without changing how the binaries are produced.

**Homebrew tap** (`Westenets/homebrew-dvai-hub`):
- Create the empty tap repo (public).
- Generate a PAT with `repo` scope; add as `HOMEBREW_TAP_GH_TOKEN`
  on `Westenets/dvai-bridge`.
- Hand-bootstrap the first formula by copying
  `hub/packaging/homebrew/dvai-hub.rb` → `Formula/dvai-hub.rb` in
  the tap repo, with the actual `version` / `url` / `sha256` from
  the v3.1.0 release.
- Test from a clean Mac:
  `brew tap deepvoiceai/dvai-hub https://github.com/Westenets/homebrew-dvai-hub`,
  `brew install dvai-hub`.
- Add a `update-homebrew-formula.yml` workflow that opens a PR to
  the tap repo on every future `v3.1.*` tag (placeholder is in the
  formula's comments).

**winget manifest:**
- Fork `microsoft/winget-pkgs` to a Westenets-controlled account.
- Take the v3.1.0 `.msi` SHA256, paste into a copy of
  `hub/packaging/winget/DeepVoiceAI.DVAIHub.installer.yaml` at
  `manifests/d/DeepVoiceAI/DVAIHub/3.1.0/`.
- Open PR upstream to `microsoft/winget-pkgs`.
- Address Microsoft's automated CI feedback (manifest validation
  can take days/weeks first time).
- Once merged, test from a clean Windows:
  `winget install DeepVoiceAI.DVAIHub`.
- Add `update-winget-manifest.yml` to auto-PR on future tags.

### Hub dogfood (pre-announcement)

Pre-announcement validation that the Hub actually does what we
claim across the full happy-path:

- Run `pnpm smoke:identity` against a freshly-installed Hub.
- Pair an Android device — either the rebuilt example app, or an
  SDK that has outgoing-offload routing wired (see "Per-SDK
  outgoing-offload routing" below).
- Verify `~/.dvai-hub/apps/<appId>/audit.log` captures cross-device
  requests (timestamp + app ID + peer device + model + response
  code).
- Sit on the install for ~a week before announcing publicly. The
  auto-update path, restart cycle, and pairing TTL all need
  real-world soak time.

---

## Code signing — DVAI Hub

DVAI Hub binaries currently ship unsigned in v3.1.0. End users see
SmartScreen / Gatekeeper warnings on first launch and have to
explicitly trust the binary. That's acceptable for early adopters;
not for a wider rollout.

### Apple

- Acquire an Apple Developer ID Application certificate ($99/year
  Apple Developer Program membership).
- Set `APPLE_SIGNING_IDENTITY`, `APPLE_CERT_BASE64`,
  `APPLE_CERT_PASSWORD`, `APPLE_NOTARIZATION_USERNAME`,
  `APPLE_NOTARIZATION_PASSWORD`, `APPLE_NOTARIZATION_TEAM_ID` as
  GitHub Actions secrets on `Westenets/dvai-bridge`.
- Drop the `if: secrets.APPLE_CERT_BASE64 != ''` guards added in
  RELEASE-CHECKLIST step C1 once the secrets are present.
- Verify a fresh install on a clean Mac doesn't show "DVAI Hub.app
  was downloaded from the internet" warnings.

### Windows

- Acquire a code-signing cert from a CA (DigiCert / Sectigo / SSL.com,
  ~$200–$700/year). EV certs reduce SmartScreen friction further but
  are pricier.
- Set `WIN_SIGNING_CERT_BASE64`, `WIN_SIGNING_CERT_PASSWORD`.
- Drop the `if: secrets.WIN_SIGNING_CERT_BASE64 != ''` guards added
  in RELEASE-CHECKLIST step C2.
- Confirm `signtool verify` against the published `.msi` returns OK.

### Tauri update signing (separate from OS code-signing)

- Generate a Tauri update keypair with `pnpm tauri signer generate`.
- Set `TAURI_SIGNING_PRIVATE_KEY` + `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`.
- This unlocks the auto-update path (Hub's Settings → "Check for
  updates"). Until then the app is install-only; updates happen via
  Homebrew / winget / re-download.

---

## Per-SDK outgoing-offload routing

Phase 3 v3.0 landed the configuration types (`OffloadConfig`),
discovery (mDNS / NsdManager), capability cache, and pairing
primitives in every SDK. The actual code that intercepts an outgoing
`/v1/chat/completions` on the source side and forwards it to a
discovered+paired peer **isn't wired yet** in any SDK.

That's why `examples/android-llama` calls Hub directly via OkHttp
instead of going through the SDK's offload path. Tracked separately
per platform:

- **Android** (`co.deepvoiceai:dvai-bridge`) — wire the OkHttp
  interceptor that consults `OffloadConfig.minLocalCapability` +
  paired peers and forwards via HMAC-signed request.
- **iOS** (`DVAIBridge`) — same shape via `URLProtocol` or a Network
  framework hook.
- **React Native** (`@dvai-bridge/react-native`) — delegates to native;
  needs the iOS + Android pieces above first.
- **Flutter** (`dvai_bridge`) — same delegation; Pigeon channel
  surface already exists.
- **.NET** (`co.deepvoiceai.dvai-bridge*`) — same on the desktop
  slice; Catalyst delegates to native.

Until any of these land, host apps wanting cross-device offload from
the SDK should call the Hub URL directly with a regular OpenAI
client. The Hub side is fully wired; the SDK glue is what's missing.

---

## v3.0 → v3.1 migration polish

- Native SDKs (`DVAIBridge` Swift, `co.deepvoiceai:dvai-bridge`
  Kotlin, `dvai_bridge` Dart, `@dvai-bridge/react-native`,
  `co.deepvoiceai.dvai-bridge` C#) need their handshake initiator
  paths updated to:
  1. Send `appId` in the v3.0 handshake body.
  2. Read `pairingKey` + `peerDeviceId` from the v3.1 handshake
     response.
  3. Sign subsequent `/v1/chat/completions` calls with
     `X-DVAI-Peer-Device-Id` / `X-DVAI-App-Id` / `X-DVAI-Nonce` /
     `X-DVAI-Signature`.
- The TypeScript core already does (1) + (2); the SDK mirrors are
  pending.

---

## Linux AppImage support

v3.1.0 ships `.deb` + `.rpm` only on Linux. `linuxdeploy-plugin-gtk`
runs `ldd` against the Bun-compiled sidecar binary
(`dvai-hub-peer-mode-x86_64-unknown-linux-gnu`) to walk shared-lib
dependencies; `bun build --compile` produces a near-static binary
with its own embedded loader, so `ldd` exits 1 and the plugin
aborts with `exit code 134`.

Possible paths to fix:

- Switch the Linux sidecar bundling away from `bun --compile` to
  something `ldd`-friendly (esbuild + node, pkg + node, or shipping
  Node alongside the Hub).
- Patch the Bun binary post-bundle so `ldd` returns success
  (e.g. `patchelf --set-interpreter` to a stock loader).
- Tell linuxdeploy-plugin-gtk to skip the sidecar via an exclude
  pattern (the plugin doesn't currently expose that knob — would
  need a fork or upstream PR).
- Drop linuxdeploy-plugin-gtk and use a different AppImage build
  pipeline (e.g. `appimagetool` directly, with hand-rolled AppDir).

Once any of these land, re-add `appimage` to the `bundles:` matrix
in `.github/workflows/dvai-hub-release.yml` and to the upload /
release-artifact globs.

---

## Hub UX gaps — to surface in a v3.1.x patch

Items the Hub dashboard / status page needs but didn't make v3.1.0:

### Per-app config UI

The Hub already has the data model (`PairingPolicy` carries
per-app TTLs / approval requirements / persistent state) but the
dashboard doesn't expose any of it. v3.1.x should surface:

- A per-app row showing app ID + display name + last-seen + active
  pairing state.
- Per-app toggle: **always allow / always deny / require approval
  per-request**. Stored in `~/.dvai-hub/apps/<appId>/config.json`
  alongside the audit log.
- Revoke button — drops the pairing key, marks the app
  un-paired; future requests trigger fresh pairing.
- Optional per-app rate limit (req/min). Probably v3.2+.

### Model load progress

When the Transformers.js backend is selected, model
download / cache-load can take 30s–5min depending on size and the
user gets no feedback. Transformers.js already emits structured
progress events:

```json
{"text":"progress_total","progress":0.00012017354630092248,"timeElapsed":0}
```

Pipe these from the worker to the Hub's React dashboard, render
as a progress bar on the status page. Should also cover initial
model fetch (network → IndexedDB) vs. warm load (IndexedDB →
WebGPU/WASM).

Apply the same pattern to llama.cpp (`progress_callback` in
`node-llama-cpp`) so non-Transformers.js backends look consistent.

---

## Phase 6+ territory (post-v3.2)

Parked here so the trail isn't lost. Mobile-Hub (DVAI Hub on iPad /
Android tablet) was previously listed and has been **explicitly
dropped from the roadmap** — the iOS background-server entitlement
story is too fragile and Android tablets aren't compelling enough
on their own.

What's left:

- **Headless Hub (NAS / Docker / Unraid)** — Synology DSM SPK,
  Docker image, Unraid template. Likely the highest-value Hub
  use-case for users with idle server hardware. Candidate for
  v3.3.0.
- **Persistent rendezvous-pairing across reboots** — currently
  rendezvous sessions are in-memory; restarts force re-pair. Only
  becomes acute once Headless Hub lands ("the NAS rebooted, now
  every phone needs to re-pair"). Pull into v3.3.x with Headless.
- **Multi-instance rendezvous scaling** — Redis-backed session
  store so the WebSocket relay scales horizontally past one VM.
  Phase 7 / v4.0 territory; only matters if rendezvous traffic
  outgrows one box.
- **Multi-user / federated Hub** — Phase 7 / v4.0. "DVAI Hub Pro":
  per-user audit logs, quotas, optional centralized policy + Hub-
  to-Hub mesh discovery so a household with multiple capable
  devices forms an inference cluster.
- **TensorRT-LLM as a first-party backend** — parked per the
  Phase 4 spec; revisit when the build chain stabilizes.
- **CLI diagnostics tool** — `dvai-bridge cli peers`, `... probe`,
  `... pair`. Useful for ops without the Tauri UI.
- **Voice / image pipelines as first-class Hub-side capabilities**
  — Hub today is LLM-shaped (`/v1/chat/completions`). Whisper-in
  + TTS-out on Hub would unlock real assistant UX without a cloud
  round-trip. Probably v3.3+.

---

## See also

- `RELEASE-CHECKLIST.md` — short-term release-prep tracker (TEMP file
  that gets deleted once Hub ships via Homebrew + winget).
- `docs/superpowers/specs/` — design specs (private).
- `docs/superpowers/plans/` — execution plans (private).
