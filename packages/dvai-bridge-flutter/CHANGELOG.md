# Changelog — `dvai_bridge` (Flutter plugin)

All notable changes to the `dvai_bridge` Flutter plugin are documented here.
Version numbers track the parent `dvai-bridge` family: bump in lockstep with
the iOS / Android / React Native packages.

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
