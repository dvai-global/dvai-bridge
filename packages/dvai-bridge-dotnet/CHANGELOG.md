# Changelog — `@dvai-bridge/dotnet`

All notable changes to the .NET NuGet family. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [2.4.0]

Initial release.

### Added

- `DVAIBridge` facade package (NuGet.org, `net10.0`) — singleton-style
  `DVAIBridge.Shared` with `StartAsync` / `StopAsync` / `GetStatusAsync` /
  `DownloadModelAsync` and an idiomatic
  `IAsyncEnumerable<ProgressEvent> ProgressEvents` reactive surface backed
  by `System.Threading.Channels`.
- `DVAIBridge.iOS` binding package (multi-target:
  `net10.0-ios26.2`, `net10.0-maccatalyst26.2`; runtime floor iOS 15.1 /
  Mac Catalyst 15.1) — Obj-C bindings around an `@objc` Swift wrapper
  (`DVAIBridgeNetBridge`) re-exporting the `DVAIBridge.shared` actor's API
  surface. The wrapper xcframework is bundled inside the NuGet, so consumers
  do not need a SwiftPM auth.
- `DVAIBridge.Android` binding package (`net10.0-android36.0`, runtime floor
  API 24) — Java/Kotlin bindings around `co.deepvoiceai:dvai-bridge:2.4.0`,
  pulled from GitHub Packages Maven at consumer build time.
- `DVAIBridge.Desktop` package (`net10.0`) — desktop-native llama.cpp slice
  for Windows / macOS / Linux. Ships native binaries via NuGet's
  `runtimes/<rid>/native/` mechanism. Auto-pulled by the facade on bare
  `net10.0` consumers.
- `DVAIBridge.OnnxRuntime` package (`net10.0`) — opt-in cross-platform
  ONNX Runtime + GenAI backend. Adds `BackendKind.Onnx` and works on every
  platform the family runs on.
- `DVAIBridge.MLNet` package (`net10.0`) — opt-in desktop-only ML.NET +
  `OnnxScoringEstimator` backend. Adds `BackendKind.MLNet` for apps already
  using ML.NET pipelines.
- Cross-platform `BackendKind` enum (`Auto`, `Llama`, `Foundation`, `CoreML`,
  `MLX`, `MediaPipe`, `LiteRT`, `Onnx`, `MLNet`) with runtime platform
  validation in the facade and defense-in-depth checks in the native
  bindings.
- xUnit test suites for all four projects: facade (`DVAIBridge.Tests`),
  desktop slice (`DVAIBridge.Desktop.Tests`), ONNX slice
  (`DVAIBridge.OnnxRuntime.Tests`), ML.NET slice
  (`DVAIBridge.MLNet.Tests`).

### Fixed

- `ProgressBroadcaster.Subscribe(ct)` now exits cleanly via yield-break on
  consumer-side cancellation instead of propagating
  `OperationCanceledException` out of the consuming `await foreach`. See
  [migration v2.3 → v2.4](../../docs/migration/v2.3-to-v2.4.md#progressbroadcaster-cancellation-fix-bugfix).

### Notes

- This is the family's third public registry (after CocoaPods Trunk for
  iOS and pub.dev for Flutter). All other family members ship through
  GitHub Packages. See
  [migration v2.3 → v2.4](../../docs/migration/v2.3-to-v2.4.md).
- WinUI 3 / Avalonia / desktop consumers compile cleanly against the
  facade but every API call throws `DVAIBridgeException(BackendUnavailable)`
  at runtime. Native desktop backends are a Phase 4+ candidate.
- NativeAOT is **not** supported for the binding slices in v2.4 — the
  Obj-C / JNI marshalling produces trim warnings. Phase 4 candidate.
