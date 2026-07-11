# Changelog — `dvai_bridge` (Flutter plugin)

All notable changes to the `dvai_bridge` Flutter plugin are documented here.
Version numbers track the parent `dvai-bridge` family: bump in lockstep with
the iOS / Android / React Native packages.

## [4.2.1] — 2026-07-11

Re-publish of the LiteRT-LM feature release. **Use 4.2.1, not 4.2.0.**

v4.2.0 had two CI mishaps that stopped it from publishing to npm,
CocoaPods, and NuGet (a stale `pnpm-lock.yaml` blocked npm publish,
and Git LFS missing-object errors on the LiteRT-LM Android prebuilts
killed the iOS xcodebuild step). Maven Central and pub.dev did publish
at 4.2.0 successfully — but the feature is only whole at 4.2.1.

No feature or API differences vs. 4.2.0. Bump straight to 4.2.1.

## [4.2.0] — 2026-07-11 [PARTIAL — USE 4.2.1]

Adds **LiteRT-LM** — Google's cross-platform on-device LLM runtime — as a new
backend across the family. One `.litertlm` weight file runs on browser (via
`@litert-lm/core`), iOS/macOS (via `@dvai-bridge/ios-litertlm-core`, SwiftPM),
and Android (via `@dvai-bridge/android-litert-core`). Metal on Apple Silicon,
CPU fallback elsewhere; WebGPU in the browser.

### Flutter surface

- `BackendKind.litertlm` — new cross-platform enum case. The Dart-to-native
  wire uses the canonical `"litertlm"` string; the deprecated Android-only
  `BackendKind.litert` alias is retained for legacy callers.
- Pigeon-generated channel code accepts both `"litert"` (legacy) and
  `"litertlm"` (canonical) on the wire; new consumers should use `litertlm`.
- iOS floor for the LiteRT-LM path is iOS 17 / macOS 14 (matches
  `dvai-bridge-ios-shared-core` / Hummingbird). Other backends unaffected.

### Changed (family-wide)

- Capacitor: new `@dvai-bridge/capacitor-litertlm` plugin (dual-platform).
- React Native: `BackendKind.LiteRTLM` added to the TurboModule surface;
  wire name unified to `"litertlm"` across iOS and Android.
- iOS umbrella: `.litertlm` case added to `BackendKind`; `.litertlm` file
  extension now auto-resolves via `backend: .auto`.

## [4.1.0] — 2026-06-20

Maintenance release. No API changes — `dvai_bridge 4.0.x` consumers upgrade
without touching their code. Family-wide v4.1.0 bump driven by a Dependabot
refresh pass across the monorepo (11 PRs landed as one batch).

### Changed (family-wide, no Flutter API impact)

- Flutter dev_dependencies: `pigeon` constraint widened from `^26.3.4` to
  `">=26.3.4 <28.0.0"` — accepts Pigeon 27.x without forcing the major
  upgrade. Existing 26.x-generated channel code stays compatible.
- React Native tooling bumped to `0.86.0` family (`@react-native/babel-preset`,
  `codegen`, `eslint-config`, `gradle-plugin`, `jest-preset`, `metro-config`,
  `typescript-config`) plus `react-native-builder-bob 0.42.1`. RN runtime
  stays at `0.85.3`. No impact on Flutter consumers.
- .NET package versions refreshed (`Microsoft.ML.OnnxRuntimeGenAI` 0.13.1 →
  0.14.0, `Microsoft.NET.Test.Sdk` 18.5.1 → 18.6.0,
  `Microsoft.SourceLink.GitHub` 8.0.0 → 10.0.300). No impact on Flutter.
- JS dev tooling refreshed (`vitest` 4.1.5 → 4.1.9, `vite` 8.0.14 → 8.0.16,
  `eslint` to 10.4.1 in examples, `@langchain/core` to 1.1.48). Used by the
  monorepo's tests and examples — not reached by Flutter consumers.
- Docs site bumps (`vue` 3.5.35 → 3.5.38, `vitepress-plugin-llms` patch).

## [4.0.2] — 2026-05-28

Maintenance release. No API changes — `dvai_bridge 4.0.x` consumers upgrade
without touching their code. Rides along with a family-wide v4.0.2 bump
driven by a dependency-maintenance pass across the monorepo.

### Changed (family-wide, no Flutter API impact)

- Dependency refresh from the Dependabot batch: GitHub Actions runners
  (`setup-node` v6, `actions/cache` v5, `setup-dotnet` v5, `labeler` v6),
  plus JS-side dev tooling (Babel, typescript-eslint, esbuild, msw,
  `@react-native/*` 0.85.3, `@tauri-apps/cli`). None reach the Flutter
  consumer surface.
- `@noble/curves` 1.x → 2.x in the JS `@dvai-bridge/core` package
  (rendezvous E2EE key exchange). Migrated to the v2 export path +
  `randomSecretKey` API; X25519 ECDH round-trip verified. Flutter's
  native rendezvous path is unaffected (it uses platform crypto, not
  the JS lib).
- README positioning section ("Isn't this just LiteLLM / LangChain /
  Ollama?") now shipped on the pub.dev landing — clarifies that
  DVAI-Bridge embeds the runtime + OpenAI HTTP inside your app rather
  than being a gateway (LiteLLM) or an end-user-installed server (Ollama).

## [4.0.1] — 2026-05-24

Patch release. No API changes — `dvai_bridge 4.0.0` consumers can upgrade
without touching their code. Primarily refreshes pub.dev metadata and rides
along with a family-wide v4.0.1 bump driven by infrastructure fixes in the
sibling iOS / .NET / Android packages.

### Fixed

- **pub.dev `Example` tab link** — `example/README.md` referenced the stale
  `dvai-bridge.deepvoiceai.co` host (pre-rename leftover). pub.dev archives
  are immutable per-version, so the corrected link only ships in a new
  version. Now points at the canonical
  [`bridge.deepvoiceai.co`](https://bridge.deepvoiceai.co) docs site.
- **In-IDE doc tooltips** — `lib/src/offload.dart` doc-comments carried the
  same stale host; updated so `flutter doc` / hover tooltips link to the
  live docs.

### Changed (family-wide, no Flutter API impact)

- iOS umbrella + .NET binding restore the **Mac Catalyst** slice that was
  dropped in v4.0.0 — only affects `DVAIBridge.iOS` NuGet consumers running
  under `net10.0-maccatalyst`. Flutter plugin's iOS side is unaffected.
- 13 transitive dependency bumps via Dependabot (Babel, jest, vue,
  @types/*, etc.) — no impact on the Flutter consumer surface; only the
  monorepo's JS tooling moved.
- Three iOS test-target source bugs in sibling Capacitor packages cleared
  (XCTest deployment-target mismatch, missing `HandlerContext` import,
  obsolete platform floor). Flutter plugin's tests were already green.

## [4.0.0] — 2026-05-19

First pub.dev publish. Tracks the v4.0.0 release of the DVAI Bridge family
(npm `@dvai-bridge/*` at 4.0.0; Maven Central `co.deepvoiceai:dvai-bridge`
at 4.0.0; CocoaPods `DVAIBridge` at 4.0.0). See the docs site for the full
[v3 → v4 migration guide](https://bridge.deepvoiceai.co/migration/v3.2-to-v4.0).

### Changed

- Native Android dependency now resolves from **Maven Central** instead of
  GitHub Packages — no tokens or repo entries required in consumer
  Android projects.
- iOS deployment target bumped to **15.1** (matches the iOS umbrella).
- Pigeon channel surface regenerated against Pigeon 26.3.4 for Dart 3.7
  compatibility.

### Added

- Distributed-inference primitives reach the Flutter plugin via the
  updated Pigeon channel — `BackendKind.offload` now honors the offload
  proxy config introduced in v3.0.
- DVAI Hub pairing support — Flutter apps on the same Wi-Fi as a Hub
  install can offload heavy inference. See the
  [DVAI Hub guide](https://bridge.deepvoiceai.co/guide/dvai-hub).

## [2.3.0] — 2026-04-27

Initial release of the Flutter plugin. See
[`docs/migration/v2.2-to-v2.3.md`](https://bridge.deepvoiceai.co/migration/v2.2-to-v2.3)
for the broader v2.3 family rollout context.

### Added

- Unified Flutter plugin (`dvai_bridge`, snake_case per Dart convention)
  wrapping the existing iOS (`DVAIBridge` Swift package, v2.3) and Android
  (`co.deepvoiceai:dvai-bridge` AAR, v2.3) native SDKs behind a single Dart
  facade.
- 4-method lifecycle API: `start`, `stop`, `status`, `downloadModel`.
- Reactive `Stream<DVAIBridgeState>` and `Stream<ProgressEvent>` getters,
  composable with `StreamBuilder`, Riverpod `StreamProvider`, and Bloc.
- `BackendKind` Dart enum covering the union of all 7 platform backends:
  `auto`, `llama`, `foundation`, `coreml`, `mlx`, `mediapipe`, `litert`.
- Cross-platform validation in the Dart facade: iOS-only and Android-only
  backends throw `DVAIBridgeError.backendUnavailable` before crossing the
  Pigeon channel.
- Pigeon-generated, type-safe platform channels (`@HostApi()` for the four
  lifecycle methods, `@EventChannelApi()` for the progress stream).
