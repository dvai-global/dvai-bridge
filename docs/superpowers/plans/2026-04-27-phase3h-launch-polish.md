# Phase 3H Implementation Plan — Docs + Build + Marketing + Research Polish (v2.4.1)

**Spec:** [2026-04-27-phase3h-launch-polish-design.md](../specs/2026-04-27-phase3h-launch-polish-design.md)
**Date:** 2026-04-27
**Target tag:** v2.4.1
**Branch:** `main` (no feature branch — 3H is editorial; commits land directly).

---

## Task ordering

Tasks 1–7 below are written to be executed in order. Earlier tasks set the conceptual ground (what we ship → what we tell people we ship → how to build it → how to demo it → how to launch it → what the paper says) so each task can lean on the deliverables of the previous one.

```
1. README + CONTRIBUTING
   ↓
2. VitePress public docs
   ↓
3. docs/development/ contributor pages   ┐
                                         │   independent: any of 3, 4, 5
4. Per-platform build scripts            │   can run in parallel after 2
                                         │
5. Marketing/demo automation             ┘
   ↓
6. RESEARCH.md rewrite + new figure(s)
   ↓
7. v2.4.1 bump + tag + push + GitHub Releases (v2.4.0 backfill + v2.4.1)
```

---

## Task 1 — Root README + CONTRIBUTING.md

### What

- Edit `README.md`:
  - Supported-platforms table: add React Native row, add Flutter row, fix .NET row (correct NuGet ID `co.deepvoiceai.dvai-bridge*`, list Llama / ONNX Runtime / ML.NET / Mac Catalyst).
  - Replace the "**React Native / Flutter / Tauri:** ... near-term roadmap" paragraph with one that says both shipped and links to their guides.
  - Fix iOS install snippet repo URL (currently `dvai-bridge-swift`, should be `dvai-bridge`'s SwiftPM target; cross-reference what the actual `Package.swift` exposes).
  - Bump install snippets from `1.0.0` examples to `2.4.1`.
  - Add a "Contributing" section (3-5 lines): "We welcome PRs. See [CONTRIBUTING.md](./CONTRIBUTING.md). For per-platform contributor docs, see [docs/development/](./docs/development/)."
  - Update top-of-file badges if needed (Node, TypeScript, Swift, Kotlin, .NET versions match what's actually pinned in v2.4.x).
- Create `CONTRIBUTING.md` (repo root, ~80–120 lines):
  - PR flow (branch, build, test, open PR with linked issue).
  - Commit-message convention with examples lifted from existing git log.
  - Per-platform pointers: "for iOS, see docs/development/contributing-ios.md; for Android, ..."
  - License + copyright (commercial repo; contributions assign copyright per LICENSE).
  - Code of conduct sentence (1 line, no separate CoC file).

### Verify

- `git diff README.md` shows the changes.
- Visual scan: every install snippet's package coordinate copy-pastes correctly.
- `CONTRIBUTING.md` renders cleanly on GitHub (preview in IDE; no broken links).

### Commit

`docs(phase3h): refresh README + add CONTRIBUTING.md`

---

## Task 2 — VitePress public docs

### What

- `docs/index.md`:
  - Replace hero `tagline` with "One local OpenAI server, embedded in your Web, iOS, Android, React Native, Flutter, or .NET app." (or a similar phrasing — final wording at impl time).
  - Features list: add a "📱 6 SDKs, one API" feature; refresh "Native Support" feature copy.
- `docs/.vitepress/config.ts`:
  - Update `description` field to match new tagline.
- `docs/guide/introduction.md`:
  - "The MOAT" bullet list: add Flutter row + .NET MAUI/Catalyst row.
  - "Hybrid backend selection" §: name .NET routing per platform.
- `docs/guide/comparison.md`:
  - Read fully first (~not-yet-inspected).
  - Add RN / Flutter / .NET coverage to whatever comparison axes the page currently uses.
- `docs/.vitepress/config.ts` sidebar:
  - Add a new top-level section "Contributing" with 5 entries (one per SDK) — pages will be created in Task 3 but referenced here so the sidebar is ready.

### Verify

- `cd docs && pnpm install && pnpm run build` (or whatever the docs build command is) succeeds with **no dead-link warnings**.
- New sidebar entries render. (For a hot-reload check, `pnpm run dev` if available.)

### Commit

`docs(phase3h): refresh VitePress home + introduction + comparison for v2.4 family`

---

## Task 3 — docs/development/ per-SDK contributor pages

### What

Create 5 new pages under `docs/development/`. Each page is ~80–150 lines and follows this template:

```markdown
# Contributing: <SDK> Native SDK

## Prerequisites
- Tool 1 (version pin + install command)
- Tool 2
- ...

## Build + test loop
```bash
cd packages/<pkg>
<tool-specific build command>
<tool-specific test command>
```

## Common breakage modes
- Symptom 1 → cause → fix
- Symptom 2 → ...

## Related docs
- Link to `docs/guide/<sdk>-sdk.md` (user-facing)
- Link to existing cross-cutting `docs/development/*.md`
```

Per-page content:

- **`contributing-ios.md`** (Mac-only):
  - Prereqs: Xcode 16+, CocoaPods (already installed), Ruby (system).
  - Build: `cd packages/dvai-bridge-ios && xcodebuild test -scheme DVAIBridge-Package -destination "platform=iOS Simulator,name=iPhone 16,OS=18.5"`.
  - Pod lint: `pod lib lint DVAIBridge.podspec --allow-warnings`.
  - Common issues: Pods cache (`pod cache clean --all`), simulator OOM (kill stale procs), code-signing (use auto for tests).
  - Link to `mac-remote-builds.md` for Windows-host workflows.

- **`contributing-android.md`**:
  - Prereqs: JDK 23 (`JAVA_HOME`), Android SDK 36 (`ANDROID_HOME`), Gradle wrapper auto-fetched.
  - Build: per-module `./gradlew assemble test`. Five modules to know: shared-core, llama-core, mediapipe-core, litert-core, umbrella.
  - Common issues: stale JNI libs, NDK mismatch, Gradle daemon hangs.
  - Link to `litert-lm-migration-notes.md` for backend-internals context.

- **`contributing-react-native.md`**:
  - Prereqs: Node 25+, RN 0.77+ floor for testing the example app, iOS Pods + Android Gradle.
  - TurboModule codegen: `pnpm codegen` from `packages/dvai-bridge-react-native/`.
  - Build + test: example-app workflow (iOS sim + Android emulator).
  - Why no JS-side state machine: all state lives in the native `DVAIBridge` shared instance per platform; the JS layer is a thin `NativeModules` wrapper.

- **`contributing-flutter.md`**:
  - Prereqs: Flutter 3.41+ or 3.39+ (matrix); Dart 3.7+; Pigeon (dev dep).
  - Pigeon codegen: `dart run pigeon --input ...` (exact command — read from `packages/dvai-bridge-flutter/`).
  - Build + test: `flutter pub get && flutter analyze && flutter test`.
  - AGP 8.7.3 pin: explain why (Flutter 3.41 plugin tooling not yet AGP-9-ready); link to known follow-ups in `migration/v2.2-to-v2.3.md`.

- **`contributing-dotnet.md`**:
  - Prereqs: `dotnet 10.0.203` LTS exact pin; workload install command (Mac: `sudo dotnet workload install ios maccatalyst android`; Windows: `dotnet workload install android` and skip ios/catalyst).
  - Build: `dotnet restore && dotnet build -c Release` from `packages/dvai-bridge-dotnet/`.
  - Test: `dotnet test` per testable csproj (DVAIBridge, DVAIBridge.Desktop, DVAIBridge.OnnxRuntime, DVAIBridge.MLNet).
  - llama.cpp binary fetch: `bash scripts/fetch-llama-binaries.sh && bash scripts/verify-llama-checksums.sh` from `packages/dvai-bridge-dotnet/`.
  - TFM rationale: `net10.0-ios26.2` not `18.0` (link to `migration/v2.3-to-v2.4.md`).
  - Mac Catalyst host requirement: only macOS hosts can pack the Catalyst slice.

### Verify

- Each page parses as VitePress markdown (no missing frontmatter; no broken anchors).
- `pnpm run build` for docs succeeds.
- Sidebar from Task 2 navigates to each new page.

### Commit

`docs(phase3h): per-SDK contributor pages under docs/development/`

---

## Task 4 — Per-platform build scripts

### What

Create 7 (Bash) + 1 (PowerShell) build scripts under `scripts/`. Each script:

1. Detects host (`uname -s` → `Darwin` / `Linux`; `$OSTYPE` for Windows). Bails with a clear error if run on the wrong host.
2. Runs `command -v <tool>` preflight checks and emits an install hint per missing tool.
3. Executes the build + test commands for its slice.
4. Exits non-zero on any failure.

Scripts:

- **`scripts/build-web.sh`** — `pnpm install --frozen-lockfile && pnpm -r run build && pnpm test`. Runs on any host.
- **`scripts/build-ios.sh`** — Mac-only. Calls existing `mac-side-build.sh` + `mac-side-test.sh` in sequence. Wraps the existing scripts; no logic duplication.
- **`scripts/build-android.sh`** — Any host with JDK + Android SDK. Iterates the 5 Android modules (`shared-core`, `llama-core`, `mediapipe-core`, `litert-core`, umbrella) and runs `./gradlew assemble test` per module.
- **`scripts/build-react-native.sh`** — RN package's example app workflow. Skips gracefully if no example app present.
- **`scripts/build-flutter.sh`** — `flutter pub get && dart run pigeon --input pigeons/messages.dart && flutter analyze && flutter test` from `packages/dvai-bridge-flutter/`. Pigeon command exact-match what's already in CI.
- **`scripts/build-dotnet.sh`** — Workload check, then `dotnet restore && dotnet build -c Release && dotnet test && dotnet pack --include-symbols -o ./artifacts` per testable csproj. Skip Catalyst on non-Mac.
- **`scripts/build-all.sh`** — Orchestrator. Detects host, runs the slices that work there. Emits a final summary like:
  ```
  Build summary:
    web:           ✅ 12.3s
    ios:           ✅ 95.2s
    android:       ✅ 47.1s
    react-native:  ✅ 60.4s
    flutter:       ✅ 22.8s
    dotnet:        ✅ 31.7s
    ──────────────────────
    Total:         269.5s; 6/6 slices green
  ```
- **`scripts/build-all.ps1`** — Windows mirror. Calls `wsl bash scripts/build-all.sh` if WSL is detected (preferred path on Windows for full matrix). Otherwise runs `.NET + Web + Android` directly via PowerShell.

### Verify

- Mac: `bash scripts/build-all.sh` completes green (full matrix).
- Windows: `pwsh scripts/build-all.ps1` completes green (`.NET + Web + Android` subset, with a "ios + catalyst skipped (Mac-only)" note).
- Each individual `scripts/build-<slice>.sh` runs green standalone.

### Commit

`build(phase3h): per-platform build scripts + orchestrator`

---

## Task 5 — Marketing/demo automation

### Sub-task 5a — Committed demo recorder

Create:
- `scripts/record-demo.sh` (Bash, Mac/Linux):
  - Args: `<demo-yaml-path> [--dry-run]`.
  - Parses the YAML (yq if available; fallback to a small awk parser since YAML schemas here are flat).
  - Schema:
    ```yaml
    name: web-react-quickstart
    description: Hello-world flow on the React example
    output: docs/marketing/assets/web-react-quickstart.mp4
    fps: 30
    scenes:
      - duration: 5
        caption: "Open the app"
      - duration: 10
        caption: "Type a prompt; see streaming response"
        zoom: { x: 100, y: 100, w: 800, h: 600 }
      - duration: 3
        caption: "Closing"
    ```
  - Runs `ffmpeg` (Mac/Linux) to capture the screen for `sum(durations)` seconds.
  - In `--dry-run` mode, parses + prints the planned scene list and exits 0.
- `scripts/record-demo.ps1` (PowerShell, Windows):
  - Same args + schema.
  - Wraps either `ffmpeg.exe` or OBS CLI (whichever is installed; preflight check).
- `scripts/demos/` directory with 7 YAML files:
  - `web-react.yaml`, `capacitor.yaml`, `ios-native.yaml`, `android-native.yaml`, `react-native.yaml`, `flutter.yaml`, `dotnet-maui.yaml`.
  - Each is a 3-5-scene flow drafted from the SDK guide page's quickstart example.
- `scripts/demos/README.md`:
  - YAML schema reference.
  - How to add a new flow.
  - "What this script doesn't do": run the example app, click UI elements, post-edit the video. User starts the app; recorder captures; user can edit in their NLE of choice afterwards.

### Sub-task 5b — Gitignored launch playbook

Create under `docs/marketing/` (already gitignored):

- `docs/marketing/CALENDAR.md`:
  - Day 0 — Tag goes public on GitHub: cut GH Release for v2.4.1, post Show HN with under-150-word pitch, link the Releases page.
  - Day 1 — Reddit posts: r/LocalLLaMA (focus: "OpenAI-compatible local server, on every platform"), r/Flutter (focus: "first-class Flutter plugin shipped"), r/dotnet (focus: "MAUI + ONNX Runtime + ML.NET, all local"), r/reactnative.
  - Day 3 — Long-form blog post on deepvoiceai.co (or chosen venue). Lead with the moat: 6 SDKs, 9 backends, one HTTP surface. Link to the research paper.
  - Day 7 — Twitter/X thread: 8-tweet sequence, one per SDK + intro/closer. Reuses video clips from `record-demo.sh` outputs.
  - Day 14 — Follow-up post: early adopter quotes (if any), benchmarks if collected, retro on what shipped vs. what didn't.
  - Each day has: target audience, concrete venue links (HN submit URL, subreddit URLs), pitch one-liner, asset checklist.
- `docs/marketing/blog/launch-v2.4.md` — long-form launch piece (1500-2000 words) with sections: problem (cloud-only AI doesn't ship), solution (embedded local server, every platform), what's new in v2.4, how to install on each SDK in 30 seconds, what's next.
- `docs/marketing/blog/per-sdk/` — 6 short pieces (300-500 words each), one per SDK. Reuses the long-form's structure but tuned to one platform's audience.
- `docs/marketing/social/hn.md` — HN Show HN copy (under 150 words).
- `docs/marketing/social/reddit-localllama.md` — r/LocalLLaMA copy.
- `docs/marketing/social/reddit-flutter.md`, `reddit-dotnet.md`, `reddit-reactnative.md`, `reddit-androiddev.md`, `reddit-iosdev.md`.
- `docs/marketing/social/x-thread.md` — 8-tweet sequence.
- `docs/marketing/social/linkedin.md` — LinkedIn post copy (longer-form than X; targets a hiring/decision-maker audience).
- `docs/marketing/CHECKLIST.md` — pre-publish checklist:
  - [ ] All 6 SDK install snippets in README copy-paste cleanly.
  - [ ] CHANGELOG [2.4.1] entry exists.
  - [ ] GitHub Release draft saved.
  - [ ] All demo MP4s rendered (8 total — 7 SDKs + 1 hero clip).
  - [ ] Research-paper PDF regenerated.
  - [ ] Social copy drafted in all venues.
- `docs/marketing/assets/.gitkeep` — empty placeholder so the dir exists; user populates locally.

### Verify

- `bash scripts/record-demo.sh scripts/demos/web-react.yaml --dry-run` parses + prints the scene list + exits 0.
- `pwsh scripts/record-demo.ps1 scripts/demos/web-react.yaml -DryRun` does the same.
- `git status` confirms nothing under `docs/marketing/` is staged for commit.
- Tracked files limited to `scripts/record-demo.{sh,ps1}` + `scripts/demos/*.yaml` + `scripts/demos/README.md`.

### Commit

`feat(phase3h): demo-recording scripts + per-SDK demo flows`

(Plus an unstaged-and-ignored `docs/marketing/` tree on the local disk.)

---

## Task 6 — RESEARCH.md rewrite + new figure(s)

### What

Edit `RESEARCH.md` in-place (don't rewrite from scratch — preserve existing prose where it's still accurate):

- **§Abstract** — extend ~2 sentences to mention 6 SDKs + 9 backends + the OpenAI-mock-as-universal-interface pattern as the central tech contribution.
- **§3.2 driver table** — replace the 3-row table with a **family-grouped 9+ row table**:
  ```
  | Family | Backend | Model format | Streaming | Target |
  |---|---|---|---|---|
  | **Web/JS** | WebLLMBackend | MLC-compiled | True async-iterator | Browser, WebGPU |
  | | TransformersBackend | ONNX | True token-level | Browser + Node |
  | **iOS** | iOS-Llama | GGUF | True token | iOS device + sim |
  | | iOS-CoreML | mlpackage | True token | iOS A14+ |
  | | iOS-Foundation | Apple Foundation Models | True token | iOS 18.4+ |
  | | iOS-MLX | MLX safetensors | True token | iOS A17+ |
  | **Android** | Android-Llama | GGUF | True token | Android arm64 |
  | | Android-MediaPipe | MediaPipe LLM Inference | True token | Android |
  | | Android-LiteRT | TFLite | True token | Android |
  | **.NET** | Desktop-Llama (P/Invoke) | GGUF | True token | win/mac/linux |
  | | .NET-ONNX | ONNX | True token | .NET 10 cross-platform |
  | | .NET-MLNet | ONNX (via ML.NET) | Per-call | .NET 10 desktop |
  ```
- **§3.5** — extend "React and Vanilla Wrappers" to mention the SDK family lineage:
  ```
  Beyond the React + Vanilla wrappers, DVAI-BRIDGE exposes parallel native
  SDKs that present the same OpenAI HTTP contract from inside their host
  language: a Capacitor plugin for hybrid mobile, an iOS Swift Package and
  an Android AAR for native mobile, a React Native TurboModule, a Flutter
  plugin, and a .NET NuGet family covering iOS + Android (via .NET MAUI),
  Mac Catalyst, and Windows / macOS / Linux desktop. All seven SDKs share
  the same handler logic, the same OpenAI endpoint set, and the same
  Backend / state / progress contract.
  ```
- **§6 Case Studies** — add 5 new subsections (~150 words each):
  - 6.6 iOS-native LangChain via the Swift OpenAI client.
  - 6.7 Android-native via OkHttp + Vercel AI SDK in Compose.
  - 6.8 React Native via openai-node over the TurboModule.
  - 6.9 Flutter via dart:io HttpClient + Riverpod.
  - 6.10 .NET MAUI on Catalyst via Microsoft.SemanticKernel.
- **§8.0 Shipped since v1** (new section) — bulleted list of what's done as of v2.4. Position before §8.1.
- **§8.1 Roadmap** — slim to: `/v1/audio/*`, `/v1/images/*`, signed-token license validation, published benchmarks.
- **§9 Limitations** — refresh:
  - Drop "Test coverage is selective; 35 tests across five files."
  - Drop "Desktop/Electron path is implicit."
  - Keep "no published benchmarks."
  - Add: "MLC LLM is parked (see `docs/research/2026-04-27-mlc-llm-backend-feasibility.md`)."
- **References** — add citations as needed for new claims (Apple Foundation Models, MLX, MediaPipe LLM Inference, ML.NET, ONNX Runtime GenAI).

### New figure(s)

Create:
- `docs/public/paper-assets/fig6-platform-coverage.svg` — lattice diagram. SDKs on Y-axis (Web, iOS, Android, RN, Flutter, .NET); backends on X-axis (Llama, Foundation, CoreML, MLX, MediaPipe, LiteRT, ONNX, MLNet, WebLLM, Transformers); filled cells = supported. Authoring: a small inline-SVG written by hand (or with the project's existing figure-generation pattern — check existing figs to see if there's a tool).

(Optional `fig7-driver-matrix.svg` deferred to user choice during impl; ship fig6 only unless time permits.)

Reference fig6 in §3.2: insert `![Figure 6 — Platform × backend coverage](paper-assets/fig6-platform-coverage.svg)` directly under the new driver table.

### Regenerate PDF

`node scripts/build-research-pdf.mjs` — runs the existing pipeline. Verify:
- No Pandoc errors.
- New figure embeds.
- Updated tables render.

### Verify

- `git diff RESEARCH.md` shows the changes.
- `node scripts/build-research-pdf.mjs` produces an updated PDF.
- New SVG renders (open in browser to confirm).

### Commit

`docs(phase3h): RESEARCH.md major refresh + fig6 platform coverage`

---

## Task 7 — v2.4.1 bump + tag + push + GitHub Releases

### Sub-task 7a — Version bump

```bash
# 1. Bump root.
# Edit package.json: 2.4.0 -> 2.4.1.

# 2. Cascade to all packages + Directory.Build.props.
node scripts/sync-versions.js
node scripts/sync-package-meta.js

# 3. CHANGELOG entry: prepend [2.4.1] section above [2.4.0]:
#    """
#    ## [2.4.1] — 2026-04-27
#
#    Phase 3H — documentation, build tooling, and research-paper polish.
#    No code changes; no consumer-visible API surface change. Patch-bump
#    keeps the repo, packages, and research paper at one citeable
#    version.
#
#    ### Added
#    - CONTRIBUTING.md at repo root.
#    - 5 per-SDK contributor pages under docs/development/.
#    - 7 per-platform build scripts + a top-level orchestrator.
#    - Demo-recording scripts (record-demo.sh / .ps1) + 7 per-SDK YAML
#      flows under scripts/demos/.
#    - RESEARCH.md fig6 (platform × backend coverage) and 5 new case
#      studies (iOS / Android / RN / Flutter / .NET).
#
#    ### Changed
#    - README.md supported-platforms table now lists all 6 SDKs with
#      correct package coordinates; removed "RN/Flutter coming soon".
#    - VitePress home + introduction reflect the v2.4 family.
#    - RESEARCH.md §3.2 driver table expanded from 3 to 12 rows;
#      §6 case studies expanded to all SDKs; §8.1 roadmap slimmed
#      to genuinely-unfinished items.
#
#    No breaking changes. No migration guide needed (no API surface
#    change).
#    """
```

### Sub-task 7b — Commit + tag

```bash
git add -A
git commit -m "chore(release): bump versions to 2.4.1 + tag v2.4.1 (Phase 3H)"
git tag -a v2.4.1 -m "v2.4.1 — Phase 3H (docs + build + marketing + research polish)"
git push origin main
git push origin v2.4.1
```

### Sub-task 7c — GitHub Releases (v2.4.0 backfill + v2.4.1)

```bash
# v2.4.0 backfill (currently only the tag exists; no Release page).
gh release create v2.4.0 \
  --title "v2.4.0 — Phase 3G (.NET NuGet family)" \
  --notes-file <(awk '/^## \[2\.4\.0\]/,/^## \[2\.3\.0\]/' CHANGELOG.md | sed '$d')

# v2.4.1.
gh release create v2.4.1 \
  --title "v2.4.1 — Phase 3H (launch polish)" \
  --notes-file <(awk '/^## \[2\.4\.1\]/,/^## \[2\.4\.0\]/' CHANGELOG.md | sed '$d')
```

### Verify

- `git log --oneline -2` shows the bump commit + the prior 3H docs commit.
- `git tag --list | tail -3` shows `v2.4.0`, `v2.4.0` (sorted), `v2.4.1`.
- `gh release list` shows both v2.4.0 and v2.4.1 with release pages.
- `cat package.json | jq -r .version` returns `2.4.1`.
- `cat packages/dvai-bridge-dotnet/Directory.Build.props | grep Version` returns `<Version>2.4.1</Version>`.

### Commit

(Already covered by Sub-task 7b's commit + tag.)

---

## Final 3H gate

After Task 7 lands:

1. `git status` is clean.
2. `git log --oneline -8` shows a chronological 3H sequence:
   - `chore(release): bump versions to 2.4.1 + tag v2.4.1 (Phase 3H)`
   - `docs(phase3h): RESEARCH.md major refresh + fig6 platform coverage`
   - `feat(phase3h): demo-recording scripts + per-SDK demo flows`
   - `build(phase3h): per-platform build scripts + orchestrator`
   - `docs(phase3h): per-SDK contributor pages under docs/development/`
   - `docs(phase3h): refresh VitePress home + introduction + comparison for v2.4 family`
   - `docs(phase3h): refresh README + add CONTRIBUTING.md`
   - `chore(release): bump versions to 2.4.0 + tag v2.4.0 (Phase 3G)` (already on main)
3. `gh release list | head -3` shows `v2.4.1`, `v2.4.0`, `v2.3.0` with description bodies.
4. Fresh-clone smoke test on a Mac: `bash scripts/build-all.sh` runs green.

3H is closed; Phase 3 is closed; the v2.x story is fully shipped, documented, and citeable.

---

## What we deliberately are NOT doing

- Pushing to NuGet / npm / Maven / pub.dev. ("Do not publish packages" — user instruction.)
- Sending the marketing posts. (Drafts only; user decides when/where to publish.)
- Renaming or deleting any existing file under `scripts/` or `docs/development/`. (Additive only; the existing `mac-side-*.sh` scripts continue to work as-is.)
- Touching code under `packages/*/src/`. (3H is editorial + tooling only.)
- Adding a CLA bot. (Commercial repo; existing LICENSE governs contributions.)
- Adding a separate Code of Conduct file. (One-line CoC sentence inside CONTRIBUTING.md is sufficient at this scale.)
- Running benchmarks or producing perf claims. (RESEARCH.md §6.5 stays honest; no fake numbers.)
- Creating a feature branch. (3H is editorial; commits land directly on main, same as 3F's tag-bump landed on main.)
