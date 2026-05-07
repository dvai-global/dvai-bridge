# Post-v2.4 Phase 2 — (SDK × Backend) Examples Matrix

**Status:** Draft (2026-05-07) — pre-implementation
**Date:** 2026-05-07
**Scope:** Build a runnable, tested example app for every supported (SDK × backend) combination in the v2.4 family. Each example: minimum viable code, the platform's idiomatic OpenAI client, model download instructions, a focused `README.md`, and an entry in `scripts/demos/*.yaml` so the marketing-recording flow covers it. Library bugs surfaced during example construction get fixed on the library side.

## 1. Goals

1. **One app per supported combo.** A developer evaluating a specific SDK + backend can clone the repo, follow ≤5 lines of setup, and run a working app that hits a local OpenAI-compatible endpoint.
2. **Idiomatic on each platform.** Each example uses the platform's preferred OpenAI client (`@langchain/openai` for JS, OpenAI Swift SDK for iOS, `aallam/openai-kotlin` for Android, official OpenAI .NET SDK + Microsoft.SemanticKernel for .NET, `dart:io HttpClient` + Riverpod for Flutter, `openai-node` over the TurboModule for RN).
3. **Library bugs get fixed, not worked around.** If an example surfaces a missing API, a build break, a docs error, or a developer-ergonomics issue, the library-side fix lands as part of Phase 2 — the example does not paper over it.
4. **Demo-flow alignment.** Every example has a corresponding `scripts/demos/*.yaml` entry the marketing recorder can drive.
5. **Tested end-to-end where the host can.** Each example has a smoke check that verifies "the local OpenAI endpoint responds with a non-empty completion to a fixed prompt." Where the host can run it (Windows for .NET / Web / Android emulator; Mac via `ssh mac` for iOS / Mac Catalyst), it gets executed; where it can't, the smoke check is documented and gated behind the relevant CI job.

## 2. The matrix

| # | SDK | Backend | Host that can build+run |
|---|---|---|---|
| 1 | Web (React) | Transformers.js | any |
| 2 | Web (React) | WebLLM | any with WebGPU browser |
| 3 | Web (vanilla JS, no build step) | Transformers.js | any |
| 4 | Node | Transformers.js | any |
| 5 | Node | llama.cpp (`node-llama-cpp`) | any with the native dep |
| 6 | Capacitor (iOS+Android hybrid) | llama.cpp | Mac for iOS pod-install; any for Android |
| 7 | iOS native (Swift) | llama.cpp | Mac |
| 8 | iOS native | Foundation Models | Mac + iOS 26+ device/sim |
| 9 | iOS native | CoreML | Mac |
| 10 | iOS native | MLX | Mac (Apple Silicon) |
| 11 | Android native (Kotlin) | llama.cpp | Mac or Windows + JDK + Android SDK |
| 12 | Android native | MediaPipe LLM | same |
| 13 | Android native | LiteRT | same |
| 14 | React Native | (delegates — single combined example covering iOS + Android backends via flag) | Mac for iOS, Windows/Mac for Android |
| 15 | Flutter | (delegates — single combined example) | Mac for iOS, Windows/Mac for Android |
| 16 | .NET MAUI | (delegates — single combined example targeting iOS + Android + Mac Catalyst) | Mac (full); Windows (Android-only subset) |
| 17 | .NET Desktop | llama.cpp | any |
| 18 | .NET Desktop | ONNX Runtime GenAI | any |
| 19 | .NET Desktop | ML.NET | any |

19 example apps. Two of them (#1, #4) already exist (`web-react`, `node-langchain`); the other 17 need scaffolding.

## 3. Surface (deliverables)

### 3.1 Per-example contents

Each new example lives at `examples/<example-name>/` with:

- **`README.md`** (≤120 lines) — what it shows, prereqs, how to run, what model is downloaded on first run, how to swap the model, where in the code the OpenAI client points at the local endpoint, and a "what to look for" section for the demo-recording flow.
- **Manifest** appropriate for the platform: `package.json` for JS/RN/Capacitor, `Package.swift` for iOS, `build.gradle.kts` for Android, `pubspec.yaml` for Flutter, `.csproj` / `.sln` for .NET.
- **One source file** with the minimum app — model load, OpenAI client construction against `dvai.baseUrl`, one chat-completion call (streamed), output to console / UI. No multi-screen UIs; no state management beyond what the framework forces.
- **Smoke test script** (`smoke.sh` or equivalent) that runs the example to "first non-empty token" and exits 0 / 1.

### 3.2 Per-example `scripts/demos/<name>.yaml`

Already exists for the 7 primary SDK quickstarts; needs to extend per backend variant. Format unchanged from Phase 3H. Each new example gets a YAML with 4–6 scenes covering: open app, configure backend (or show the backend's config), trigger inference, see streaming response, closing card.

### 3.3 Library-side fixes

Surfaced during example construction. Tracked inline as commits. Examples of expected friction:

- API mismatch between docs and the package's actual exports (already fixed one round in Phase 3H).
- Workspace-install ergonomics (e.g., the `prepare`-runs-`build`-recursively issue from Phase 1).
- Missing TypeScript types for native-bridge surfaces.
- Path conventions in published artefacts that consumers can't easily replicate.

The rule: if the friction would hit a real consumer building their first app against the library, fix it library-side. Document the fix in the relevant CHANGELOG entry.

## 4. Non-goals

- **Production-shape apps.** No multi-screen UIs, no auth flows, no model browsers, no chat history persistence. Each example teaches one thing.
- **Benchmarks.** Per the v2.4 paper §6.11 reframe, perf is the upstream backend's responsibility. Examples don't include `tok/s` claims.
- **Production model selection.** Each example pins one tested model per backend; "which model is best for X" is out of scope.
- **Cross-example consistency on UI.** Each platform's example follows that platform's idiomatic UX. Not chasing a unified design system.

## 5. Scope decisions

### Q1: One example per combo, or one example per SDK with backend-as-flag?

**Decision:** Mostly one-per-combo, but RN / Flutter / .NET MAUI use a single example with a backend selector (radio buttons / dropdown) because they delegate to the underlying native backends — duplicating the example per backend would only change one config value and triple the maintenance.

### Q2: Where do the example apps for Capacitor / native iOS / Android live? Same `examples/` directory, or per-platform sub-trees?

**Decision:** All in `examples/` at one level. Naming convention `<sdk>-<backend>` (e.g. `ios-llama`, `android-mediapipe`, `dotnet-desktop-onnx`). The native examples don't need to be pnpm-workspace members; they're self-contained sub-projects. Add `examples/.gitignore` for the platform-specific build outputs (iOS `DerivedData`, Android `build/`, .NET `bin`/`obj`) that aren't already gitignored at root.

### Q3: How do native-iOS examples integrate with the SwiftPM target — by `:path` reference or via CocoaPods?

**Decision:** SwiftPM `:path` to the in-monorepo package. Easy local dev; consumers see the SwiftPM URL form in the docs. Each iOS example's `Package.swift` references `.package(path: "../../packages/dvai-bridge-ios")` so changes to the SDK reflect immediately. Same pattern for Flutter (path-dep in `pubspec.yaml`) and Android (Gradle composite build pointing at `packages/dvai-bridge-android`).

### Q4: Models — bundled, or downloaded on first run?

**Decision:** Downloaded. Bundling adds GBs to a clone and requires LFS. Each example's README documents the model it downloads, where it caches, and how big it is. The first-run download is part of the demo-flow YAML (with a wide `duration` for the download scene).

### Q5: Smoke-test gating — block on every host or selectively?

**Decision:** Selectively. The smoke test for each example is gated by host capability:
- Always: web examples (any host with Chrome / WebGPU).
- Mac-only: iOS, Catalyst, Apple Silicon-only MLX.
- Any-host-with-tools: .NET (any), Android (with JDK + Android SDK), Flutter (with Flutter installed).
A `scripts/run-example-smoke.sh` orchestrator runs whatever the current host supports and skips the rest with a clear message.

### Q6: How do we keep the matrix in sync with the actual list of supported backends?

**Decision:** A `examples/MATRIX.md` (committed) lists every (SDK × backend) combo with the path to the example, host requirements, and the YAML demo-flow path. CI drift-checks this against `scripts/demos/` so missing examples surface as a CI failure.

### Q7: Mac access via `ssh mac` — synchronous or batched?

**Decision:** Batched. Mac builds are slow (Xcode + simulator boot + first-run pod install). Build all the iOS-related examples in one Mac SSH session (`scripts/mac-side-build-examples.sh`) rather than ssh-ing per example. Same for Catalyst.

## 6. Risks

- **R1: 17 new examples is a lot of surface.** Mitigation: parallel-agent dispatch by SDK family (Web/Node, iOS, Android, RN+Flutter, .NET) so 5 agents work concurrently on disjoint paths. Estimated wall-clock ~3 hours with parallelism vs. ~10 hours sequential.
- **R2: Library-side fixes may need their own version bumps.** Mitigation: bundle them into a single 2.4.2 patch at the end of Phase 2; don't bump per-fix.
- **R3: Mac access via SSH may be flaky.** Mitigation: Phase 2's Mac builds are batched and resumable — if SSH drops, the next agent retry picks up where it left off.
- **R4: Smoke tests may need real model downloads on CI hosts.** Mitigation: smoke tests use the smallest tested model per backend (≤500 MB); CI cache keyed on model hash; pre-warm cache via a CI job.
- **R5: .NET MAUI sample is the largest single piece** — it has to handle three platforms (iOS / Android / Catalyst) inside one Visual Studio solution. Mitigation: scaffold from the `dotnet new maui` template and add only the dvai-bridge wiring, keep stock UI.

## 7. Verification plan

- **Per example:** `bash examples/<name>/smoke.sh` returns 0; the README's "expected output" matches actual.
- **Per host:** `bash scripts/run-example-smoke.sh` runs every example the host supports; prints a per-example pass/fail summary.
- **Cross-cutting:** `examples/MATRIX.md` parses; every SDK × backend in the matrix has a directory; every directory has a YAML demo flow; every smoke test exits 0 on at least one host (Mac+Windows combined coverage).
- **Library-side:** any commits made under "library fix surfaced during examples" get a follow-up `pnpm test` + relevant native test pass.

## 8. Effort estimate

| Sub-task | Estimate (parallelised across agents) |
|---|---|
| Update existing 2 examples to v2.4 polish | already done in Phase 1 |
| Web vanilla-cdn + Node-llama-cpp examples (2) | 30 min |
| iOS examples × 4 (Llama / Foundation / CoreML / MLX) | 90 min (Mac SSH batched) |
| Android examples × 3 (Llama / MediaPipe / LiteRT) | 60 min |
| Capacitor example | 30 min |
| RN unified example | 40 min |
| Flutter unified example | 40 min |
| .NET MAUI unified example | 60 min |
| .NET Desktop × 3 (Llama / ONNX / MLNet) | 60 min |
| `examples/MATRIX.md` + `scripts/demos/*.yaml` updates | 30 min |
| Smoke-test orchestrator | 30 min |
| Library-side fixes (estimated) | 60 min (variable) |
| Verification + commit + 2.4.2 bump | 60 min |
| **Total wall-clock** | **~7-8 hours with parallelism** |

Sequential single-pass would be ~12-15 hours. Use parallel agents.

---

## 9. Plan-document outline

The plan (`docs/superpowers/plans/2026-05-07-phase2-examples-matrix.md`) decomposes this into:

1. **Pre-flight:** workspace ready, Mac SSH check, demo-YAML schema confirmed.
2. **Web/Node group** (Agent A): 2 new examples, library fixes if any.
3. **iOS group** (Agent B): 4 examples, Mac SSH driven.
4. **Android group** (Agent C): 3 examples.
5. **Hybrid group** (Agent D): Capacitor + RN + Flutter (3 examples).
6. **.NET group** (Agent E): MAUI + 3 desktop variants.
7. **Cross-cutting:** MATRIX.md, demo YAMLs, smoke orchestrator.
8. **Verification on Windows + via Mac SSH.**
9. **Library-side patch bump (2.4.2) + tag.**
