# Phase 3H — Docs + Build + Marketing + Research Polish (v2.4.1)

**Status:** Draft (2026-04-27) — pre-implementation
**Date:** 2026-04-27
**Scope:** End-of-Phase-3 polish landing as v2.4.1. Closes the staleness gap between what the v2.4.0 family actually ships (6 SDKs across Web, iOS, Android, RN, Flutter, .NET — 9 backends) and what the public-facing surface (README, VitePress site, RESEARCH.md paper) still claims. Adds per-SDK contributor docs, per-platform build helpers, a reproducible demo-recording flow, a private launch playbook + calendar, and a substantially-rewritten research paper that documents what was actually built.

**Sub-phase position in Phase 3:**

```
3A core extraction ✅ → 3B LiteRT-LM migration ✅ → 3C iOS SDK ✅
                                                  → 3D Android AAR ✅
                                                  → 3E React Native ✅
                                                  → 3F Flutter ✅
                                                  → 3G .NET NuGet ✅
                                                  → 3H Launch polish ◀️ YOU ARE HERE
```

3H is the **final** Phase 3 sub-phase. After 3H lands the v2.x story is complete: every SDK is shipped, documented for both end-users and contributors, has a reproducible build + demo flow, has a launch playbook, and is reflected in the research paper. Anything beyond 3H is post-launch (Phase 4 territory).

---

## 1. Goals

1. **Public-facing docs match shipped reality.** A reader landing on the GitHub README, the VitePress home, or the introduction page sees all 6 SDKs immediately and can install any of them with copy-paste accuracy. No "coming soon" lines for things already shipped. No wrong NuGet IDs. No missing rows in the platforms table.
2. **Contributor onboarding works for every platform.** A new contributor cloning the repo can run a per-platform build + test loop without spelunking. `docs/development/` covers iOS (Mac-only), Android, RN, Flutter, and .NET as first-class contributor pages alongside the existing `testing.md` / `handler-parity.md` / `mac-remote-builds.md`.
3. **Per-platform build scripts.** Each platform has a single-purpose script under `scripts/` that builds + verifies its slice end-to-end. A top-level orchestrator wires them. The existing monolithic `mac-side-*.sh` family stays as iOS-specific helpers (renamed for clarity if needed); new scripts cover Flutter, .NET, RN, and Web.
4. **Reproducible demo + launch flow.** `scripts/record-demo.{sh,ps1}` wraps a screen recorder + a YAML-defined demo flow so v2.x marketing videos are reproducible. Private launch material (blog drafts, social copy, calendar) lives in gitignored `docs/marketing/` so the user owns evolution.
5. **Research paper reflects shipped reality.** RESEARCH.md updates §3 (driver table 3 → 9 rows), §6 (case studies expanded to all 6 SDKs), §8.1 (move shipped items out of "future work"), §9 (limitations refresh). Two new figures land alongside the existing five.
6. **Patch-tagged release.** All of the above ships as v2.4.1, tagged from the 3H landing commit, so future readers can cite "the v2.4.1 paper" / "the v2.4.1 README" against a stable git ref.

---

## 2. Non-goals

- **No new public-API surface.** 3H is purely editorial + build-tooling + demo-flow + paper. Code under `packages/*/src/` is untouched.
- **No package republish.** v2.4.1 is a docs-only patch. NuGet / npm / Maven / pub.dev publishes happen at v2.5+ when the next code change ships, or are batched at user request — not auto-driven by 3H.
- **No actual marketing posts.** Content drafts land in private `docs/marketing/` only. Hitting "publish" on HN / Reddit / Twitter is the user's call, not Claude's.
- **No new model-bench numbers.** RESEARCH.md §6.5 ("What Remains Unmeasured") stays as honest disclosure. 3H doesn't run benchmarks; it documents what's already shipped.
- **No CONTRIBUTING.md outside the repo's existing license model.** Contribution guidelines describe how to send a PR; they do **not** modify the commercial license terms in LICENSE.

---

## 3. Surface (deliverables)

### 3.1 Root README + CONTRIBUTING

- `README.md`:
  - Supported-platforms table gains `React Native` + `Flutter` rows; .NET row gets correct NuGet IDs (`co.deepvoiceai.dvai-bridge*`) and lists Llama / ONNX Runtime / ML.NET / Catalyst.
  - Drops the misleading "RN/Flutter coming soon" paragraph.
  - Corrects the iOS install snippet repo URL (currently points at `dvai-bridge-swift` which doesn't exist; actual is the `dvai-bridge` repo's SwiftPM target).
  - Bumps version pins in install snippets from `1.0.0` examples → `2.4.1`.
  - Adds a 1-paragraph "Contributing" section that links to `CONTRIBUTING.md`.
- `CONTRIBUTING.md` (new, repo root):
  - PR flow (branch from main, run `pnpm install && pnpm -r run build`, run platform-relevant build script, open PR).
  - Per-platform "I want to contribute to X" sub-sections that point at the relevant `docs/development/<sdk>.md` page.
  - Commit-message convention (already established: `feat(phase3X-...)`, `chore(release): ...`, `docs(...)`, `fix(...)`).
  - License + CLA expectations (this is a commercial repo; external contributions assign copyright per LICENSE).

### 3.2 VitePress public docs

- `docs/index.md`:
  - Hero `tagline`: replace "Unified LLM inference for Web, Capacitor, and Electron with zero cloud costs." with one that names the 6-SDK story (e.g. "One local OpenAI server, embedded in your Web, iOS, Android, React Native, Flutter, or .NET app.").
  - Features list: add a "📱 6 SDKs, one API" feature; refresh the existing "Native Support" feature to name iOS / Android / RN / Flutter / .NET.
- `docs/.vitepress/config.ts`:
  - `description` field: same staleness as `index.md`. Updated in lockstep.
- `docs/guide/introduction.md`:
  - "The MOAT" bullet list: add `Flutter (Dart, via pub.dev — dvai_bridge)` row; add explicit `.NET MAUI / Avalonia / WinUI mobile + desktop` row to make the `.NET-on-iOS` and `.NET-on-Android` story visible.
  - "Hybrid backend selection" §: update to mention .NET routes (Catalyst → Foundation/MLX, Android → MediaPipe/LiteRT, Desktop → Llama/ONNX).
- `docs/guide/comparison.md` (didn't read in full yet — confirm during impl):
  - "vs. other tools" comparison must enumerate `dvai-bridge` features per SDK; add columns/rows for RN / Flutter / .NET as applicable.

### 3.3 docs/development/ — per-SDK contributor pages

New files:
- `docs/development/contributing-ios.md` — Mac-only build flow, simulator selection (`platform=iOS Simulator,name=iPhone 16`), `xcodebuild test -scheme DVAIBridge-Package`, podlint command, common breakage modes (Pods cache, simulator OOM, cert/team).
- `docs/development/contributing-android.md` — `JAVA_HOME` + `ANDROID_HOME` setup, `./gradlew :module:test`, AGP version, NDK toolchain notes, JNI debugging tips.
- `docs/development/contributing-react-native.md` — TurboModule codegen, RN 0.77 floor, Metro cache reset, iOS Pods + Android Gradle integration, why we don't ship JS-side state machines (it's all in core).
- `docs/development/contributing-flutter.md` — Pigeon codegen, Flutter SDK 3.41 / 3.39 matrix, AGP 8.7.3 pin rationale, `flutter analyze && flutter test`, why we don't use the federated plugin model.
- `docs/development/contributing-dotnet.md` — `dotnet 10.0.203` LTS pin, workload install (`ios maccatalyst android`), TFM rationale (`net10.0-ios26.2` not `18.0` — see migration v2.3-to-v2.4), `dotnet test` per csproj, llama.cpp binary fetch step, Mac Catalyst host requirement.

Existing files stay (they're cross-cutting): `testing.md`, `handler-parity.md`, `mac-remote-builds.md`, `litert-lm-migration-notes.md`. The new pages link to the existing ones rather than duplicate content.

VitePress sidebar (`docs/.vitepress/config.ts`) gets a new "Contributing" section listing the 5 new pages.

### 3.4 Per-platform build scripts

New under `scripts/`:
- `scripts/build-web.sh` — `pnpm install --frozen-lockfile && pnpm -r run build && pnpm test`. Smoke check for the JS family.
- `scripts/build-ios.sh` — wraps the existing `mac-side-*.sh` family for one-call iOS build + test (Mac-only; emits a clear error on Windows).
- `scripts/build-android.sh` — `JAVA_HOME` + `ANDROID_HOME` check, then iterates `dvai-bridge-android-*` modules running `./gradlew assemble test`.
- `scripts/build-react-native.sh` — pods install + Gradle assemble for the RN bridge package's example app (or skip if not present).
- `scripts/build-flutter.sh` — `flutter pub get && dart run pigeon ... && flutter analyze && flutter test` from `packages/dvai-bridge-flutter/`.
- `scripts/build-dotnet.sh` — workload check, `dotnet restore && dotnet build -c Release` per csproj, `dotnet test` for testable projects, `dotnet pack --include-symbols` for verification of NuGet-readiness.
- `scripts/build-all.sh` — orchestrator. Detects host (Mac vs. Windows vs. Linux) and runs only the platforms that can build there; prints a summary of skipped slices.
- Optional: `scripts/build-all.ps1` — Windows-side mirror of `build-all.sh` so PowerShell users have the same one-liner. Calls `wsl bash scripts/build-all.sh` if WSL present, else runs the Windows-supported subset (.NET + Web + Android) directly.

`mac-side-build.sh` etc. stay (they already work and are referenced in CI). The new `build-ios.sh` is a thin wrapper around them so the contributor doesn't have to remember the exact `mac-side-*` filenames.

### 3.5 Marketing + demo automation

**Committed (under `scripts/`):**
- `scripts/record-demo.sh` — Bash wrapper around `ffmpeg` (Mac/Linux) + a YAML-driven demo-flow file. Records the screen, optionally zooms / annotates per the YAML, outputs MP4 + a thumbnail PNG.
- `scripts/record-demo.ps1` — Windows mirror using OBS CLI or `ffmpeg` for Windows.
- `scripts/demos/` — directory of YAML flow files, one per SDK example app. Tracked in git (small text files; reproducible flows).
  - `scripts/demos/web-react.yaml`
  - `scripts/demos/capacitor.yaml`
  - `scripts/demos/ios-native.yaml`
  - `scripts/demos/android-native.yaml`
  - `scripts/demos/react-native.yaml`
  - `scripts/demos/flutter.yaml`
  - `scripts/demos/dotnet-maui.yaml`
- `scripts/demos/README.md` — explains the YAML schema (what fields the recorder reads), how to add a new flow, what the recorder won't do (e.g. it doesn't run the example app — the user starts the app, then runs the recorder against the visible window).

**Gitignored (under `docs/marketing/` — already in .gitignore):**
- `docs/marketing/CALENDAR.md` — launch sequence playbook. Day 0 = GH Release + Show HN, Day 1 = r/LocalLLaMA + r/Flutter + r/dotnet, Day 3 = blog post on deepvoiceai.co (or wherever), Day 7 = Twitter/X thread, Day 14 = follow-up post with early adopter reactions. Each day has a "what to publish" + "where" + "checklist of links to include".
- `docs/marketing/blog/` — drafts for the launch blog post(s). At least one canonical "Introducing dvai-bridge v2.4" piece + per-SDK shorter pieces.
- `docs/marketing/social/` — Reddit / HN / X / LinkedIn copy. Each variant tuned to its venue (HN = under-150-word Show HN; Reddit = problem-solution pitch; X = thread).
- `docs/marketing/assets/` — placeholder for video clips, hero images, badges. (Actual binary assets are user-supplied; the dir gives them a home.)
- `docs/marketing/CHECKLIST.md` — pre-publish checklist (badges flipped, GH Release exists, all install snippets actually work, NuGet / pub.dev pages live, etc.).

### 3.6 RESEARCH.md rewrite

- **§Abstract** — extend to mention 6 SDKs and 9 backends; keep the MSW story as the central technical contribution.
- **§3.2 driver table** — expand from 3 rows (WebLLM / Transformers / Native-Capacitor) to 9: WebLLM, Transformers.js, Capacitor-Llama, iOS-Llama, iOS-Foundation, iOS-CoreML, iOS-MLX, Android-Llama, Android-MediaPipe, Android-LiteRT, Desktop-Llama (.NET P/Invoke), .NET-ONNX, .NET-MLNet. (13 rows — the matrix really is that wide. We'll group them visually by SDK family.)
- **§6 Case Studies** — add subsections:
  - 6.6: iOS-native LangChain via the Swift OpenAI client.
  - 6.7: Android-native via OkHttp + the Vercel AI SDK in a Compose app.
  - 6.8: React Native via the openai-node package over the TurboModule-bound HTTP server.
  - 6.9: Flutter via `dart:io` HttpClient + Riverpod.
  - 6.10: .NET MAUI on Catalyst via Microsoft.SemanticKernel.
- **§8.0 Shipped since v1** (new section): bulleted list of what's now done (RN, Flutter, native iOS, native Android, .NET — both mobile and desktop, ONNX Runtime, ML.NET, Mac Catalyst).
- **§8.1 Roadmap** — slim down to the genuinely unfinished items: `/v1/audio/*`, `/v1/images/*`, signed-token license validation, published benchmarks. Remove the items that shipped.
- **§9 Limitations** — refresh:
  - Drop "Test coverage is selective" sentence (now hundreds of tests across the family).
  - Drop "Desktop/Electron path is implicit" (.NET Desktop is first-class as of v2.4.0).
  - Keep "no published benchmarks" — still honest.
  - Add: "MLC LLM is parked (see research/2026-04-27-mlc-llm-backend-feasibility.md)".
- **New visuals** under `docs/public/paper-assets/`:
  - `fig6-platform-coverage.svg` — lattice diagram: Web / iOS / Android / RN / Flutter / .NET on one axis, the 9 backends on the other, filled cells = supported. Communicates the matrix at a glance.
  - `fig7-driver-matrix.svg` — same data, alternate rendering: per-SDK "what backends do I get" stack. (Pick one to ship; both feel redundant — defer the second to user choice during impl.)

### 3.7 v2.4.1 patch tag

- Bump root `package.json` 2.4.0 → 2.4.1.
- Run `node scripts/sync-versions.js` + `node scripts/sync-package-meta.js`. Cascades to all 36 packages + `Directory.Build.props`.
- CHANGELOG.md gets a `[2.4.1] — 2026-04-27` entry: "Documentation, build tooling, and research-paper polish. No code changes; no consumer-visible API surface change. Patch-bumped to keep the repo, packages, and research paper at one citeable version."
- Commit `chore(release): bump versions to 2.4.1 + tag v2.4.1 (Phase 3H)`, tag `v2.4.1`, push both.

---

## 4. Open questions / design decisions

### Q1: Should `CONTRIBUTING.md` live at repo root or `docs/`?

**Decision:** Repo root. GitHub auto-surfaces a root `CONTRIBUTING.md` in the PR template's sidebar; placing it under `docs/` loses that surfacing. The README.md "Contributing" section links to `./CONTRIBUTING.md`, and the per-SDK contributor pages live under `docs/development/contributing-<sdk>.md`. That gives a 2-level structure: high-level repo flow at root, per-platform mechanics under docs/.

### Q2: Should marketing-asset binaries live in git or gitignored?

**Decision:** Gitignored. `docs/marketing/` is already excluded; binary video clips and hero images are large and would bloat the repo. The user supplies and stores them locally (e.g. on iCloud Drive or Google Drive). The gitignored `docs/marketing/assets/` directory is just a *home* for them — empty in git, populated locally.

### Q3: Should per-SDK demo YAMLs encode actual UI clicks, or just shot lists?

**Decision:** Shot lists, not click automation. UI-click automation is brittle across screen sizes / OS versions / app versions; a simple "wait N seconds, capture, advance to next scene" recorder is robust and lets the user drive the actual app manually. The YAML encodes scene timing, optional zoom regions (for callouts), and an output filename. Click automation would be Phase-4-onwards if ever.

### Q4: Should the `build-all.sh` orchestrator fail fast or continue past a per-platform failure?

**Decision:** Continue with `--continue-on-error` flag default, but emit a non-zero exit if any slice failed. CI uses `--fail-fast` to bail at the first failure. Local devs typically want to see everything that's broken in one pass.

### Q5: Should `build-dotnet.sh` actually run `dotnet pack` against NuGet.org, or just dry-run?

**Decision:** Dry-run only — emits .nupkg files into `packages/dvai-bridge-dotnet/artifacts/` and stops. Actual `dotnet nuget push` is in `PUBLISHING.md` (gitignored), executed manually. Same pattern as the Android Maven publish script — the build script is rehearsal-only; the publish script is the trigger.

### Q6: Should RESEARCH.md replace the existing 5 figures, or just append?

**Decision:** Append. The existing figs document the *original* WebLLM/Transformers/Native architecture and remain accurate for that slice. Adding fig6 (and optionally fig7) for the platform coverage matrix is purely additive. If a fig becomes wrong at a future revision, fix it then.

### Q7: Should the v2.4.1 commit + tag also trigger registry publishes?

**Decision:** No. The user has stated repeatedly: "do not publish packages." Registry publishes happen manually per `PUBLISHING.md` when the user runs them. v2.4.1 ships as a git tag + GitHub Release only; the npm / Maven / NuGet / pub.dev versions stay at 2.4.0 until the user pushes them.

### Q8: Should `record-demo.sh` ship pre-baked sample MP4s in git?

**Decision:** No (large binaries). The script + YAML flows ship; the user runs them locally to produce MP4s, which then live under the gitignored `docs/marketing/assets/`.

### Q9: Should the GitHub Release for v2.4.1 happen as part of 3H, or be deferred?

**Decision:** Yes, part of 3H. The Release uses the `[2.4.1]` CHANGELOG entry as the body. v2.4.0 also gets a backfilled GitHub Release as part of 3H (currently the tag exists but no Release page). User-facing entry point is the Releases tab; both v2.4.0 and v2.4.1 should have entries.

### Q10: How should we refer to the launch venue list?

**Decision:** The CALENDAR.md is gitignored; concrete venue list lives there. The committed README + CONTRIBUTING never mention "where we'll launch" since that's a private business decision.

---

## 5. Risks

- **R1: VitePress build breaks** when new sidebar entries are added. *Mitigation:* run `pnpm --filter docs run build` (or whatever the docs build command is) at the end of the public-docs task; fix dead links surfaced by VitePress' link checker before commit.
- **R2: Build scripts shell out to platform tools that may not be present.** *Mitigation:* every script's first action is a `command -v <tool> || (echo "<tool> not found; install via X"; exit 1)` preflight check.
- **R3: RESEARCH.md becomes too long for a single citeable paper.** *Mitigation:* keep the rewrite focused on §3.2 / §6 / §8 / §9 — don't restructure the paper. Limit additions to ~150 lines of new prose.
- **R4: New figures take longer than budgeted to design.** *Mitigation:* fig6 and fig7 are similar in content — ship fig6 only if fig7 doesn't compose easily. The §6 case study additions don't depend on figures landing.
- **R5: Marketing content drift.** *Mitigation:* CALENDAR.md is gitignored; the user owns it. We seed it once with a structured template and stop. Nothing in the public repo references launch dates.
- **R6: README contributor section conflicts with commercial license.** *Mitigation:* CONTRIBUTING.md explicitly says "this is a commercial repo; external contributions assign copyright per LICENSE." No CLA bot, no community-license framing.

---

## 6. Verification plan

For each task, the implementer runs:

| Task | Verification |
|---|---|
| 3.1 README + CONTRIBUTING | Visual diff review; check every install snippet copy-pastes into a fresh shell and resolves the right package. |
| 3.2 VitePress docs | `pnpm --filter docs run build` (or whatever the docs build command is) succeeds with no dead-link warnings. |
| 3.3 docs/development/ | Each new page: `pnpm --filter docs run build` succeeds; sidebar entry navigates to it; `// link checker` reports no broken anchors. |
| 3.4 Build scripts | `bash scripts/build-all.sh` completes green on Mac (full matrix); on Windows runs the `.NET + Web + Android` subset green. |
| 3.5 Marketing | `bash scripts/record-demo.sh scripts/demos/web-react.yaml --dry-run` parses the YAML and prints the planned scene list (no actual recording in CI). |
| 3.6 RESEARCH.md | `node scripts/build-research-pdf.mjs` (existing) regenerates the PDF; no Pandoc / KaTeX errors; new figures embed correctly. |
| 3.7 Version bump + tag | `git tag --list` shows v2.4.1; `git log --oneline -1` matches the tag; `cat package.json | jq -r .version` returns `2.4.1`; `cat packages/dvai-bridge-dotnet/Directory.Build.props | grep Version` shows `<Version>2.4.1</Version>`. |

Final 3H gate: a fresh-clone test (`git clone ... && cd dvai-edge && bash scripts/build-all.sh`) runs green on a Mac with the workloads installed.

---

## 7. Effort estimate

Per-task rough estimates (Claude-time, not human-time):

| Task | Estimate |
|---|---|
| 3.1 README + CONTRIBUTING | ~30 min |
| 3.2 VitePress docs | ~30 min |
| 3.3 docs/development/ × 5 | ~90 min |
| 3.4 Build scripts × 8 | ~90 min |
| 3.5 Marketing automation + content seed | ~90 min |
| 3.6 RESEARCH.md rewrite + new figures | ~120 min |
| 3.7 Version bump + tag + GitHub Releases | ~30 min |
| **Total** | **~8 hours** |

Single-pass; no review loops baked in (3H is editorial, not behavior-changing — review surfaces during user reading, not during automated test runs).
