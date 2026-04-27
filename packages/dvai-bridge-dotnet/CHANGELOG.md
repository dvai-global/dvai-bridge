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
- `DVAIBridge.iOS` binding package (`net10.0-ios18.0`, runtime floor iOS
  15.1) — Obj-C bindings around an `@objc` Swift wrapper
  (`DVAIBridgeNetBridge`) re-exporting the `DVAIBridge.shared` actor's API
  surface. The wrapper xcframework is bundled inside the NuGet, so consumers
  do not need a SwiftPM auth.
- `DVAIBridge.Android` binding package (`net10.0-android36.0`, runtime floor
  API 24) — Java/Kotlin bindings around `co.deepvoiceai:dvai-bridge:2.4.0`,
  pulled from GitHub Packages Maven at consumer build time.
- Cross-platform `BackendKind` enum (`Auto`, `Llama`, `Foundation`, `CoreML`,
  `MLX`, `MediaPipe`, `LiteRT`) with runtime platform validation in the
  facade and defense-in-depth checks in the native bindings.
- xUnit test suite covering facade dispatch, BackendKind validation,
  IAsyncEnumerable progress streams, and exception mapping.

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
