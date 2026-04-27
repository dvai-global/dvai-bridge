# Changelog — `dvai_bridge` (Flutter plugin)

All notable changes to the `dvai_bridge` Flutter plugin are documented here.
Version numbers track the parent `dvai-bridge` family: bump in lockstep with
the iOS / Android / React Native packages.

## [2.3.0] — Unreleased

Initial release of the Flutter plugin. See
[`docs/migration/v2.2-to-v2.3.md`](https://dvai-bridge.deepvoiceai.co/migration/v2.2-to-v2.3)
for the broader v2.3 family rollout context.

### Added

- Unified Flutter plugin (`dvai_bridge`, snake_case per Dart convention)
  wrapping the existing iOS (`DVAIBridge` Swift package, v2.2) and Android
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
