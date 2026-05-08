# RELEASE-CHECKLIST.md

> **TEMP FILE.** Delete after the first end-to-end public release of
> DVAI Hub via GitHub Releases + Homebrew + winget is verified
> healthy. This file is a working tracker, not part of the canonical
> docs.

The Phase 4 work merged to `main` at `b842440`. The pieces below are
what's still required to make `brew install deepvoiceai/dvai-hub/dvai-hub`
and `winget install DeepVoiceAI.DVAIHub` actually work.

---

## A. Sidecar bundling — code path

| # | Task | State |
|---|---|---|
| A1 | Pick a Node→single-binary bundler (bun build --compile) | ☐ |
| A2 | Add a `pnpm bundle:peer-mode` script that produces `hub/src-tauri/binaries/dvai-hub-peer-mode-<target-triple>.<ext>` | ☐ |
| A3 | Re-enable `bundle.externalBin: ["binaries/dvai-hub-peer-mode"]` in `hub/src-tauri/tauri.conf.json` | ☐ |
| A4 | Update `hub/src-tauri/src/sidecar.rs` so the production path uses the bundled binary; dev path still spawns `node dist/peer-mode/server.js` | ☐ |
| A5 | Wire `pnpm bundle:peer-mode` into `tauri.conf.json`'s `beforeBuildCommand` so the binary is regenerated on every `tauri build` | ☐ |
| A6 | Local smoke: `pnpm tauri build` → installer → install → tray launches → dashboard opens → Start triggers DVAI initialize → audit log writes | ☐ |

## B. Icon set

| # | Task | State |
|---|---|---|
| B1 | Commission a 1024×1024 master PNG (or accept a placeholder one — design can iterate post-release) | ☐ |
| B2 | Run `pnpm dlx @tauri-apps/cli icon path/to/master.png` from `hub/` to generate the full set | ☐ |
| B3 | Replace the dev placeholders in `hub/src-tauri/icons/`; delete `hub/src-tauri/icons/README.md` (it explains the placeholders) | ☐ |

## C. Code signing — DEFERRED (tracked in `TODO.md`)

Apple Developer ID + Windows code-signing cert + notarization flow.
Skip for v3.1.0; revisit when ready to ship signed binaries to a
non-developer audience. Tracked persistently in `TODO.md`.

For now, the GH Actions workflow at
`.github/workflows/dvai-hub-release.yml` is wired for signing —
when the secrets are absent, the import-cert step fails fast.
The fastest workaround for an unsigned-build pass is to gate the
signing steps behind an `if: secrets.APPLE_CERT_BASE64 != ''`
conditional, so unsigned builds still produce artifacts.

| # | Task | State |
|---|---|---|
| C1 | Gate macOS signing/notarize steps in workflow on `secrets.APPLE_CERT_BASE64 != ''` so unsigned builds work | ☐ |
| C2 | Gate Windows signing step on `secrets.WIN_SIGNING_CERT_BASE64 != ''` similarly | ☐ |
| C3 | Document the `signed=false` warning UX users will see (macOS Gatekeeper, Windows SmartScreen) | ☐ |

## D. First GitHub Release

| # | Task | State |
|---|---|---|
| D1 | Tag `v3.1.0` on `main` after A+B land | ☐ |
| D2 | Push tag to `origin` — workflow auto-fires | ☐ |
| D3 | Inspect run at `Actions → DVAI Hub — release binaries`; iterate on failures | ☐ |
| D4 | Verify three artefacts attach to the auto-created GitHub Release: `.msi`, `.dmg`, `.AppImage` (+ `.deb` / `.rpm`) | ☐ |
| D5 | Download each on the corresponding host; sanity-check installer launches the app | ☐ |

## E. Homebrew tap

| # | Task | State |
|---|---|---|
| E1 | Create `Westenets/homebrew-dvai-hub` repo (empty, public) | ☐ |
| E2 | Generate a Personal Access Token with `repo` scope; add as `HOMEBREW_TAP_GH_TOKEN` secret on `Westenets/dvai-bridge` | ☐ |
| E3 | Hand-bootstrap the first formula by copying `hub/packaging/homebrew/dvai-hub.rb` → `Formula/dvai-hub.rb` in the tap repo, with the actual `version`, `url`, and `sha256` from the v3.1.0 release | ☐ |
| E4 | Test from a clean Mac: `brew tap deepvoiceai/dvai-hub https://github.com/Westenets/homebrew-dvai-hub`, `brew install dvai-hub` | ☐ |
| E5 | Add a `update-homebrew-formula.yml` workflow that opens a PR to the tap repo on every future `v3.1.*` tag (the existing release workflow can be extended; placeholder lives in `hub/packaging/homebrew/dvai-hub.rb` comments) | ☐ |

## F. winget manifest

| # | Task | State |
|---|---|---|
| F1 | Fork `microsoft/winget-pkgs` to a Westenets-controlled account | ☐ |
| F2 | Take the v3.1.0 `.msi` SHA256 from the GH release, paste into a copy of `hub/packaging/winget/DeepVoiceAI.DVAIHub.installer.yaml` at `manifests/d/DeepVoiceAI/DVAIHub/3.1.0/` | ☐ |
| F3 | Open PR upstream to `microsoft/winget-pkgs` | ☐ |
| F4 | Address Microsoft's automated CI feedback (manifest validation can take days/weeks first time) | ☐ |
| F5 | Once merged, test from a clean Windows: `winget install DeepVoiceAI.DVAIHub` | ☐ |
| F6 | Add `update-winget-manifest.yml` to auto-PR on future tags | ☐ |

## G. Smoke + dogfood

| # | Task | State |
|---|---|---|
| G1 | Run `pnpm smoke:identity` against a freshly-installed Hub | ☐ |
| G2 | Pair an Android device (using either the rebuilt example or an SDK that has outgoing-offload routing wired) | ☐ |
| G3 | Verify `~/.dvai-hub/apps/<appId>/audit.log` captures cross-device requests | ☐ |
| G4 | Sit on the install for a week before announcing publicly — auto-update path, restart cycle, pairing TTL all need real-world soak time | ☐ |

## H. Done conditions

- All A / B / D / E / F rows checked.
- `brew install deepvoiceai/dvai-hub/dvai-hub` works on a clean Mac.
- `winget install DeepVoiceAI.DVAIHub` works on a clean Windows host.
- A user with no other dvai-bridge setup runs the installer, completes the first-run wizard, pairs their phone, sees inference offload — happy path end-to-end.

When all of the above is true, **delete this file**. Code-signing
items in `C` move into `TODO.md` for the v3.1.x or v3.2 line where
they get prioritized.
