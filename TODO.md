# TODO

Long-running items that are intentionally deferred. Items here are
**not** time-pressed — they're tracked so they don't get forgotten,
not because they need to ship next. For active release-prep, see
`RELEASE-CHECKLIST.md` (when present).

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

## Phase 5 territory (post-v3.1)

Out of scope for v3.1, parked here so the trail isn't lost:

- **Mobile-Hub flavor** — DVAI Hub for tablets / iPad. Same idea,
  different form factor, different distribution path (App Store
  rather than Homebrew/winget).
- **Multi-instance rendezvous scaling** — Redis-backed session store
  so the WebSocket relay scales horizontally past one VM.
- **Persistent rendezvous-pairing across reboots** — currently
  rendezvous sessions are in-memory; restarts force re-pair.
- **TensorRT-LLM as a first-party backend** — parked per the Phase
  4 spec; revisit when the build chain stabilizes.
- **CLI diagnostics tool** — `dvai-bridge cli peers`, `... probe`,
  `... pair`. Useful for ops without the Tauri UI.

---

## See also

- `RELEASE-CHECKLIST.md` — short-term release-prep tracker (TEMP file
  that gets deleted once Hub ships via Homebrew + winget).
- `docs/superpowers/specs/` — design specs (private).
- `docs/superpowers/plans/` — execution plans (private).
