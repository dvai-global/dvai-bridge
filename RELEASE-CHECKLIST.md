# RELEASE-CHECKLIST.md

> **TEMP FILE.** Delete after the v3.1.0 GitHub Release is published
> with all four artefacts attached and visually verified. This file
> tracks the immediate ship; everything beyond shipping (Homebrew,
> winget, dogfood soak) was deliberately scoped out of v3.1.0 and
> moved to `TODO.md`.

The Phase 4 work merged to `main` at `b842440`. v3.1.0-rc4 was
locally validated across all three host platforms (Windows MSI,
macOS arm64 DMG, Linux .deb / .rpm) before tagging, so the CI run
should reproduce a clean release.

---

## A. Sidecar bundling — code path

| # | Task | State |
|---|---|---|
| A1 | Pick a Node→single-binary bundler (bun build --compile) | ☑ |
| A2 | Add a `pnpm bundle:sidecar` script that produces `hub/src-tauri/binaries/dvai-hub-peer-mode-<target-triple>.<ext>` | ☑ |
| A3 | Re-enable `bundle.externalBin: ["binaries/dvai-hub-peer-mode"]` in `hub/src-tauri/tauri.conf.json` | ☑ |
| A4 | Update `hub/src-tauri/src/sidecar.rs` so the production path uses the bundled binary; dev path still spawns `node dist/peer-mode/server.js` | ☑ |
| A5 | Wire `pnpm bundle:sidecar` into `tauri.conf.json`'s `beforeBuildCommand` so the binary is regenerated on every `tauri build` | ☑ |
| A6 | Local smoke: `pnpm tauri build` → installer → install → tray launches → dashboard opens → Start triggers DVAI initialize → audit log writes | ☐ |

## B. Icon set

| # | Task | State |
|---|---|---|
| B1 | Commission a 1024×1024 master PNG (or accept a placeholder one — design can iterate post-release) | ☑ |
| B2 | Run `pnpm dlx @tauri-apps/cli icon path/to/master.png` from `hub/` to generate the full set | ☑ |
| B3 | Replace the dev placeholders in `hub/src-tauri/icons/`; delete `hub/src-tauri/icons/README.md` (it explains the placeholders) | ☑ |

## C. Code signing — workflow gating done; user-facing docs pending

The GH Actions workflow gates signing/notarization steps on secret
presence — missing secrets just produce unsigned artefacts (per
`133f9a9`). Procurement of real signing certs is tracked in `TODO.md`
under "Code signing — DVAI Hub" and is a prerequisite for a wider
non-developer rollout.

| # | Task | State |
|---|---|---|
| C1 | Gate macOS signing/notarize steps in workflow on `secrets.APPLE_CERT_BASE64 != ''` so unsigned builds work | ☑ |
| C2 | Gate Windows signing step on `secrets.WIN_SIGNING_CERT_BASE64 != ''` similarly | ☑ |
| C3 | Public-facing doc on how to do code-signing (Apple Developer ID, Windows EV/OV cert) and the trade-offs of running unsigned (Gatekeeper / SmartScreen behaviour, install friction, user-trust impact). Cross-link from the Hub guide and TODO.md. | ☐ |

## D. First GitHub Release

| # | Task | State |
|---|---|---|
| D1 | Tag `v3.1.0` on `main` after A+B land | ☑ (broken first attempt at `f5a0017`; pre-flight'd via rc4) |
| D2 | Push tag to `origin` — workflow auto-fires | ☑ |
| D3 | rc4 CI run produces clean artefacts on all three hosts; promote the tag to `v3.1.0` (re-tag main HEAD as `v3.1.0`) | ☐ |
| D4 | Verify four artefacts attach to the auto-created GitHub Release: `.msi`, `.dmg`, `.deb`, `.rpm` | ☐ |
| D5 | Download each on the corresponding host; sanity-check installer launches the app + tray icon shows + main window renders | ☐ |

## E. Done conditions

- All A / B / D rows checked.
- v3.1.0 GH Release page lists `.msi` / `.dmg` / `.deb` / `.rpm`.
- C3 doc published.

When all of the above is true, **delete this file** (the original
intent of "delete after Homebrew + winget" got descoped — that work
is now in `TODO.md` under "Distribution channels — Homebrew + winget").

---

## Descoped from v3.1.0 (moved to TODO.md)

The following sections were originally in this checklist but have
been moved to long-term tracking. Each is a meaningful chunk of
work that doesn't need to land before the GitHub Release goes live.

- **Homebrew tap** (was `E1–E5`) — `Westenets/homebrew-dvai-hub`
  repo + formula + auto-PR workflow.
- **winget manifest** (was `F1–F6`) — fork `microsoft/winget-pkgs`,
  paste SHA256, dance with their CI for days/weeks.
- **Smoke + dogfood** (was `G1–G4`) — `pnpm smoke:identity`,
  Android pairing E2E, audit-log verification, week of soak time
  before public announcement.

All three are in `TODO.md` under "Distribution channels" and
"Hub dogfood" respectively.
