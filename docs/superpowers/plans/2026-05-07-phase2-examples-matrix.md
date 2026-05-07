# Post-v2.4 Phase 2 Implementation Plan — Examples Matrix

**Spec:** [2026-05-07-phase2-examples-matrix-design.md](../specs/2026-05-07-phase2-examples-matrix-design.md)
**Date:** 2026-05-07
**Branch:** `main` (patch-bump 2.4.2 at end if any library fixes land).

## Task list

### Task 0 — Pre-flight (synchronous)

1. Verify `pnpm install --ignore-scripts` succeeds at repo root.
2. Verify `dotnet build` from `packages/dvai-bridge-dotnet/` succeeds.
3. Verify `ssh mac echo ok` succeeds and the Mac mirror is at the latest `main`.
4. Confirm Android SDK + JDK env vars on Windows host.
5. Create `examples/MATRIX.md` placeholder and `scripts/run-example-smoke.sh` skeleton.

### Tasks 1-5 — Parallel agent dispatch

Each agent works on a disjoint slice of the matrix. All agents follow the same pattern: scaffold → wire to local SDK → add smoke test → update the relevant `scripts/demos/<name>.yaml` → fix library-side bugs as they surface.

#### Task 1 — Web/Node group (Agent A)

- New: `examples/web-vanilla-cdn/` (no build step; `<script>` tag from jsDelivr; Transformers.js).
- New: `examples/node-llama-cpp/` (Node + `node-llama-cpp` + LangChain).
- Update: pull `examples/MATRIX.md` lines for the 4 web/node combos.
- Smoke: `bash examples/<name>/smoke.sh` returns 0 with non-empty completion.

#### Task 2 — iOS group (Agent B, drives Mac via SSH)

- New: `examples/ios-llama/` — minimal SwiftUI app, llama.cpp backend, Gemma 2B Q4 GGUF.
- New: `examples/ios-foundation/` — same shell, Foundation Models backend, no model download (iOS 26+ only).
- New: `examples/ios-coreml/` — same, CoreML backend, Llama-3.2-1B `.mlpackage`.
- New: `examples/ios-mlx/` — same, MLX backend, Llama-3.2-3B-Instruct-4bit (Apple Silicon only).
- Each SwiftPM-references `../../packages/dvai-bridge-ios` via `:path`.
- Smoke: `xcodebuild test` against an `iPhone 16` simulator destination.

#### Task 3 — Android group (Agent C)

- New: `examples/android-llama/` — minimal Compose app, llama.cpp backend, Gemma 2B Q4 GGUF.
- New: `examples/android-mediapipe/` — same shell, MediaPipe backend, Gemma `.task` bundle.
- New: `examples/android-litert/` — same, LiteRT backend, Llama-3.2-1B `.tflite`.
- Each Gradle-references the local Android module via composite build.
- Smoke: `./gradlew test connectedAndroidTest` (or `test` only if no emulator available).

#### Task 4 — Hybrid group (Agent D)

- New: `examples/capacitor-mobile/` — Capacitor app shell, Llama backend, runs on iOS + Android via the existing Capacitor plugin.
- New: `examples/react-native-app/` — RN 0.77 example app (single example with backend selector — Llama by default).
- New: `examples/flutter-app/` — Flutter example with backend dropdown (Llama / Foundation / CoreML / MLX / MediaPipe / LiteRT).
- Smoke: `flutter test`, `pnpm --filter examples/react-native-app test`, etc.

#### Task 5 — .NET group (Agent E)

- New: `examples/dotnet-maui/` — single MAUI solution targeting iOS + Android + Mac Catalyst, backend selector.
- New: `examples/dotnet-desktop-llama/` — console + minimal Avalonia UI, llama.cpp via P/Invoke.
- New: `examples/dotnet-desktop-onnx/` — console + minimal UI, ONNX Runtime GenAI.
- New: `examples/dotnet-desktop-mlnet/` — console showcasing classifier on top of dvai-bridge HTTP server.
- Smoke: `dotnet test` per project.

### Task 6 — Cross-cutting

- Finalise `examples/MATRIX.md` with all 19 entries.
- Update `scripts/demos/*.yaml` so each new example has a flow file (or extend the existing 7 to cover backend variants where appropriate).
- Implement `scripts/run-example-smoke.sh` to iterate the matrix and run host-appropriate smoke tests.
- Update `examples/README.md` to link the matrix.

### Task 7 — Verification

- Windows host: run `bash scripts/run-example-smoke.sh` — passes for Web/Node/.NET (desktop)/Android (if SDK present)/Flutter/RN.
- Mac (via `ssh mac`): run `bash scripts/run-example-smoke.sh` — passes for the iOS slice + Catalyst + everything Windows passed.
- Combined coverage: every example has a green smoke on at least one of the two hosts.

### Task 8 — Library-side fixes (if any) + 2.4.2 bump

If Tasks 1–5 surfaced library fixes, batch them into a single bump:

1. Bump root `package.json` 2.4.1 → 2.4.2.
2. Run `node scripts/sync-versions.js` + `node scripts/sync-package-meta.js`.
3. Update `CHANGELOG.md` `[2.4.2]` section listing the library fixes (concise, one bullet per fix).
4. Commit + tag `v2.4.2` + push.

If no library fixes were needed, skip the bump — Phase 2 lands on `main` without a tag.

## Final 3H gate

- `examples/MATRIX.md` has 19 rows.
- `scripts/run-example-smoke.sh` exits 0 on Windows and on Mac.
- `git status` clean.
- New CHANGELOG entry `[2.4.2]` exists if the patch tag was issued.

## Done

Phase 2 closed. Phase 3 (distributed inference / device discovery) is next — needs its own brainstorm + spec session before code.
