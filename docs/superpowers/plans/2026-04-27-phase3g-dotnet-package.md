# Phase 3G — .NET NuGet Packages Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to execute this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Branch:** `feat/phase3g-dotnet-nuget`

## Revision history

| Date       | Rev | Author    | Notes                                                                                                                                                                                                                                                                  |
|------------|-----|-----------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 2026-04-27 | 1   | dchak     | Initial 14-task plan — iOS + Android only. Tasks 1–13 implemented as v2.4.0-rc1 (committed, not yet tagged). Task 14 (final tag + NuGet.org publish) deferred until rev 2 expansion lands.                                                                              |
| 2026-04-27 | 2   | dchak     | Scope expansion. Tasks 1–13 marked done. Adds Tasks 14–26 (renumbered): Mac Catalyst slice, Desktop slice (Llama via P/Invoke + Kestrel) with cross-compile / prebuilt-fetch infra, ONNX Runtime backend, ML.NET backend, broadcaster cancellation bugfix surfaced during v2.4.0-rc1 build verification, BackendKind expansion to 9 cases, updated docs across all backends, updated CI workflow for the desktop matrix, and the final 2.4.0 tag + 6-NuGet publish step. New total: **26 tasks**, ~12 days additional effort vs the original ~3-day mobile-only scope. |

**Goal:** Stand up `packages/dvai-bridge-dotnet/` — **six NuGet packages** (`DVAIBridge` facade, `DVAIBridge.iOS` bindings + Mac Catalyst, `DVAIBridge.Android` bindings, `DVAIBridge.Desktop` Llama-via-llama.cpp slice, `DVAIBridge.OnnxRuntime` backend, `DVAIBridge.MLNet` backend) on NuGet.org. Wraps the v2.3 iOS DVAIBridge SDK + v2.4 Android DVAIBridge SDK + upstream `llama.cpp` `b8946` + Microsoft's first-party ONNX Runtime / ML.NET NuGets behind a shared C# API for .NET MAUI / Avalonia / WinUI / Mac Catalyst / desktop / console / server .NET 10 consumers.

**Architecture:** C# facade (`DVAIBridge.Shared` singleton + `IAsyncEnumerable<ProgressEvent>` progress + `ValueTask<DVAIBridgeState> GetStateAsync()` snapshot) → internal `INativeBridge` interface → one of:
- `IOSNativeBridge` (iOS + Mac Catalyst — both routed via the same instance via the multi-target `DVAIBridge.iOS` NuGet) — calls `@objc`-bound `DVAIBridgeNetBridge.shared` Swift wrapper.
- `AndroidNativeBridge` (Android) — calls Xamarin-bound `Co.Deepvoiceai.Bridge.NativeDVAIBridge` AAR.
- `DesktopNativeBridge` (Windows / macOS-desktop / Linux per RID) — `[DllImport("llama")]` into the RID-keyed `llama.cpp` `b8946` native + Kestrel ASP.NET Core minimal-API host.
- `OnnxNativeBridge` (cross-platform; opt-in via `DVAIBridge.OnnxRuntime` NuGet) — `Microsoft.ML.OnnxRuntimeGenAI.Generator` + Kestrel host.
- `MLNetNativeBridge` (desktop-primary; opt-in via `DVAIBridge.MLNet` NuGet) — `MLContext` + `OnnxScoringEstimator` + Kestrel host.

Reactive state surfaced via `ProgressBroadcaster` (per-subscriber `BoundedChannel<ProgressEvent>` with `DropOldest` over native progress callbacks).

**Tech stack (latest stable as of 2026-04-27):**
- .NET 10 (10.0.7 LTS — released November 11, 2025; supported through November 14, 2028)
- `net10.0` (facade + Desktop + ONNX + MLNet), `net10.0-ios18.0` + `net10.0-maccatalyst18.0` (iOS slice multi-target), `net10.0-android36.0` (Android bindings)
- `<SupportedOSPlatformVersion>15.1</SupportedOSPlatformVersion>` for iOS + Catalyst runtime floor (matches Phase 3C)
- `<SupportedOSPlatformVersion>24</SupportedOSPlatformVersion>` for Android runtime floor (matches Phase 3D)
- C# 14 (`<LangVersion>latest</LangVersion>`)
- Swift 5.9+ (matches Phase 3C; the @objc wrapper compiles against the same toolchain for iOS / sim / Catalyst slices)
- Kotlin 2.1.x (matches Phase 3D; only relevant if the optional shim is needed)
- xUnit 2.9.x (verify latest at task start) for tests; `Microsoft.NET.Test.Sdk` 17.x
- Central Package Management via `Directory.Packages.props`
- **llama.cpp `b8946`** (released 2026-04-27) — upstream prebuilt binaries per RID; SHA256-pinned in `scripts/llama-checksums.txt`
- **`Microsoft.ML.OnnxRuntime` 1.25.0** (released 2026-04-24) — generic ONNX runtime
- **`Microsoft.ML.OnnxRuntimeGenAI` 0.13.1** (released 2026-04-07) — LLM Generator API (KV cache, sampling, tokenizer)
- **`Microsoft.ML` 5.0.0** (released 2025-11-11, .NET 10 GA companion) — ML.NET pipeline runtime
- **`Microsoft.ML.OnnxTransformer` 5.0.0** — ONNX integration into ML.NET pipelines
- **`Microsoft.AspNetCore.App` 10.0.0** (Kestrel + minimal-API host inside library — used by Desktop / Onnx / MLNet via the `DVAIBridge.Shared.Hosting` shared-source project)

**Spec:** [`docs/superpowers/specs/2026-04-27-phase3g-dotnet-package-design.md`](../specs/2026-04-27-phase3g-dotnet-package-design.md)

**Resolution of spec open questions (decided here, applied throughout):**

1. **Package structure**: split into **six NuGet packages** (`DVAIBridge`, `DVAIBridge.iOS`, `DVAIBridge.Android`, `DVAIBridge.Desktop`, `DVAIBridge.OnnxRuntime`, `DVAIBridge.MLNet`) with TFM-conditional `<dependency>` deps in the facade's nuspec for the platform slices. ONNX / MLNet are explicit consumer-opt-in.
2. **Distribution**: NuGet.org as public packages. Family asymmetry documented in `docs/migration/v2.3-to-v2.4.md`.
3. **Streaming pattern**: `IAsyncEnumerable<ProgressEvent>` backed by `ProgressBroadcaster` (per-subscriber `BoundedChannel<T>` with `DropOldest`). Rev 1's bare `Channel<T>.CreateUnbounded` was replaced because it competition-multicasts rather than fan-out-multicasting.
4. **Min .NET version**: `net10.0` only (with `-ios18.0` + `-maccatalyst18.0` + `-android36.0` slices). No multi-target.
5. **iOS / Catalyst / Android floors**: iOS 15.1, Mac Catalyst 15.1, Android API 24 (matches the underlying SDKs, set via `SupportedOSPlatformVersion`).
6. **iOS / Catalyst bindings approach**: `@objc` Swift wrapper (`DVAIBridgeNetBridge`) + `ApiDefinition.cs` `[BaseType]` interface. Wrapper xcframework with iOS device + iOS sim + Catalyst slices bundled inside `DVAIBridge.iOS.nupkg`. **Multi-target TFM** in one csproj (decided rev 2 Q12) rather than separate `DVAIBridge.MacCatalyst` NuGet.
7. **Android bindings approach**: direct AAR binding via `<AndroidLibrary>` + `Transforms/Metadata.xml`. Optional `DVAIBridgeAndroidShim.kt` only if the auto-generated `Flow<ProgressEvent>` wrapper proves unergonomic (defer to Task 6 empirics).
8. **NativeAOT**: not in v2.4 — the binding slices are not AOT-clean. Document; consumers can opt in with trim warnings.
9. **Sample app**: out of scope (per project convention). Consumer guide at `docs/guide/dotnet-sdk.md`.
10. **Desktop slice native sourcing** (rev 2): upstream `llama.cpp` release `b8946` prebuilts per RID, fetched at CI time, SHA256-pinned. No from-source per-RID build farm in v2.4.
11. **`BackendKind.Onnx` / `BackendKind.MLNet` cross-family scope** (rev 2 Q11): **.NET-only**. iOS / Android / RN / Flutter `BackendKind` enums stay at 7 cases; .NET has 9.
12. **Mac Catalyst packaging** (rev 2 Q12): multi-target TFM in `DVAIBridge.iOS.csproj`, **not** a separate `DVAIBridge.MacCatalyst` NuGet.
13. **ONNX vs ML.NET positioning** (rev 2 Q13): both ship; ONNX is the recommended default; ML.NET is for "you're already using ML.NET pipelines." Honest overlap documented in `docs/guide/dotnet-sdk.md`.

**Phase boundaries:**

Rev 1 (mobile-only — implemented as v2.4.0-rc1):
- **Tasks 1-2** ✅: Package scaffold + Directory.Build.props + Directory.Packages.props + sln.
- **Task 3** ✅: Public C# facade types (BackendKind, StartOptions, BoundServer, etc.).
- **Task 4** ✅: Facade DVAIBridge class + INativeBridge + Channel<T>-backed IAsyncEnumerable (later refactored to `ProgressBroadcaster`).
- **Tasks 5-6** ✅: iOS Swift @objc wrapper + xcframework build script.
- **Task 7** ✅: iOS binding csproj + ApiDefinition.cs + IOSNativeBridge.cs.
- **Task 8** ✅: Android binding csproj + Transforms/Metadata.xml + AndroidNativeBridge.cs.
- **Task 9** ✅: Phase 3D Android AAR republish at 2.4.0 (build-graph alignment, no source changes).
- **Task 10** ✅: xUnit unit tests on facade with mocked INativeBridge.
- **Tasks 11-12** ✅: Docs (`dotnet-sdk.md` + migration entry) + sidebar.
- **Task 13** ✅: CI workflow (Linux + macOS matrix; build, test, pack, dry-run push).

Rev 2 (scope expansion — desktop + ONNX + ML.NET):
- **Task 14**: Mac Catalyst slice (multi-target TFM in `DVAIBridge.iOS.csproj`).
- **Task 15**: Desktop slice scaffold + RID-keyed native fetch + checksums.
- **Task 16**: Llama desktop native bridge (`LlamaNative.cs` `[DllImport]` + `LlamaServer.cs` Kestrel host) + `DVAIBridge.Shared.Hosting` shared-source project.
- **Task 17**: Desktop slice xUnit tests (Windows + Linux + macOS CI matrix; tiny-model smoke).
- **Task 18**: ONNX backend scaffold (`DVAIBridge.OnnxRuntime` csproj + `BackendKind.Onnx` wiring).
- **Task 19**: ONNX backend implementation (`OnnxNativeBridge` + `OnnxGenAIRunner` Generator API + Kestrel host).
- **Task 20**: ONNX xUnit tests (with a small Phi-3-mini-4k-instruct-onnx-int4 fixture for streaming smoke).
- **Task 21**: ML.NET backend scaffold + implementation (`DVAIBridge.MLNet` csproj + `MLNetNativeBridge` + Kestrel host).
- **Task 22**: ML.NET xUnit tests.
- **Task 23**: Fix the broadcaster cancellation bug surfaced during v2.4.0-rc1 build verification.
- **Task 24**: Update facade `BackendKind` (7 → 9 values) + `PlatformBridgeFactory` routing for all 5 native bridges.
- **Task 25**: Documentation (guide + per-backend sections + migration v2.3→v2.4 update) + CI workflow updates for desktop matrix.
- **Task 26**: Version bump 2.3.0 → 2.4.0 + CHANGELOG + tag + 6-NuGet publish (replaces rev 1 Task 14).

**Apply Phase 3C / 3D / 3E / 3F lessons up-front:**

1. **`scripts/sync-versions.js` handles all version bumps in one pass.** It has been extended in 3D-3F to know about `pubspec.yaml`, `Package.swift`, Gradle `gradle.properties`, RN `package.json`, etc. Extend it once more in Task 14 to know about `Directory.Build.props` (`<Version>` element) and the three csprojs (none of them carry per-project `<Version>` because CPM + Directory.Build.props handle it). One source of truth.
2. **`scripts/sync-package-meta.js` is the README+description sync tool.** Add the .NET package's NuGet `<Description>` / `<PackageTags>` / `<Authors>` to the metadata sync so a single edit in `package.json` propagates to the .nuspec at pack time.
3. **`console_scripts` entries can be missing in tooling** (lesson from 3D's Python-side packaging experience) — for .NET, the equivalent is `dotnet tool install` paths. We don't ship a CLI tool in 3G; non-issue.
4. **iOS depends on the existing `DVAIBridge` SwiftPM target** (Phase 3C v2.3) — but we don't expose SwiftPM auth complexity to consumers. The `DVAIBridgeNetBridge` Swift wrapper depends on `DVAIBridge` at *its* build time (CI's macos runner), bakes the result into an xcframework, and ships the xcframework inside the NuGet. Consumers see "one NuGet, no Swift toolchain required."
5. **Android dep via `co.deepvoiceai:dvai-bridge:2.4.0`** through GitHub Packages Maven. The consumer's app csproj needs the `<AndroidMavenLibrary>` repo entry — document in the consumer guide. Bump the Phase 3D AAR to 2.4.0 in the same release for build-graph consistency (Task 9).
6. **Always pin to LATEST stable** for .NET, Visual Studio, Xcode, AGP per the user's standing instruction. Re-verify on dotnet.microsoft.com / nuget.org / learn.microsoft.com at task start in case a newer patch shipped after 2026-04-27.
7. **Mirror iOS DVAIBridge / Android DVAIBridge naming where practical**, but C# uses PascalCase enum values (`BackendKind.Auto`, `BackendKind.Llama`) and PascalCase property names (`StartOptions.ModelPath`) per .NET convention. The facade class name is `DVAIBridge` (matches the SDKs); the bound Android type is renamed to `NativeDVAIBridge` via `Transforms/Metadata.xml` to avoid the collision.
8. **Cross-platform validation in C# facade.** Native bindings are still authoritative — they throw `DVAIBridgeException(Kind: BackendUnavailable)` if a consumer somehow bypasses the facade.
9. **Docs-only `example/` directory.** Per project convention, no sample app source. The consumer guide is a runnable copy-paste snippet.
10. **First .NET-targeting release is 2.4.** Earlier .NET-via-Capacitor or .NET-via-other-bridge approaches don't exist; this is greenfield.

---

---

## Rev 1 tasks (1–13) — implemented as v2.4.0-rc1

> **Status**: ✅ Complete. Tasks 1–13 below were executed in the agent run that produced `packages/dvai-bridge-dotnet/` v2.4.0-rc1. Treat the checkbox lists as historical record — the work is done. The final 2.4.0 tag + NuGet publish was deferred (rev 1 Task 14) and is now subsumed by rev 2 Task 26 (which also publishes the new Desktop / ONNX / MLNet packages).

> **Found during rev 1 verification (logged for rev 2 Task 23)**: `ProgressBroadcaster` cancellation has a subtle ordering bug where `WithCancellation(ct)`-driven exits race the `_subscribers.TryRemove(ch, out _)` cleanup with concurrent `Emit(...)` calls; under load, a cancelled consumer's already-completed channel can still receive a `TryWrite` (no-op, but Sonar / FxCop flag the pattern). Fix in Task 23.

## Task 1: Scaffold `dvai-bridge-dotnet` package + sln ✅

**Files:**
- Create: `packages/dvai-bridge-dotnet/package.json`
- Create: `packages/dvai-bridge-dotnet/DVAIBridge.sln`
- Create: `packages/dvai-bridge-dotnet/Directory.Build.props`
- Create: `packages/dvai-bridge-dotnet/Directory.Packages.props`
- Create: `packages/dvai-bridge-dotnet/.gitignore`
- Create: `packages/dvai-bridge-dotnet/README.md` (placeholder; synced via `scripts/sync-package-meta.js`)
- Create: `packages/dvai-bridge-dotnet/CHANGELOG.md` (placeholder)
- Create: `packages/dvai-bridge-dotnet/global.json` (`{"sdk":{"version":"10.0.100","rollForward":"latestFeature"}}`)
- Create directory placeholders: `src/.gitkeep`, `tests/.gitkeep`
- Update: `pnpm-workspace.yaml` (add `packages/dvai-bridge-dotnet`)
- Update: `scripts/sync-versions.js` (register `Directory.Build.props` `<Version>` as a version-tracked field)
- Update: `scripts/sync-package-meta.js` (sync README + NuGet `<Description>` / `<PackageTags>`)

- [ ] Verify latest stable on dotnet.microsoft.com: confirm .NET 10 SDK still LTS-current (10.0.7+ at time of execution); `global.json` pins to that version's `sdk.version`. Consumers on later patches roll forward via `latestFeature`.
- [ ] `package.json`: minimal — `"name": "@dvai-bridge/dotnet"`, `"version": "2.3.0"` (will be bumped by Task 14), `"private": true`, `"scripts": { "build": "dotnet build", "test": "dotnet test", "pack": "dotnet pack -c Release -o ./out", "build:xcframework": "bash src/DVAIBridge.iOS/native/build-xcframework.sh" }`. Marked `private: true` because the actual publish is to NuGet.org, not npm.
- [ ] `Directory.Build.props` (root of `packages/dvai-bridge-dotnet/`):
  ```xml
  <Project>
    <PropertyGroup>
      <Version>2.3.0</Version>          <!-- bumped by Task 14 -->
      <Authors>Deep Voice AI</Authors>
      <Company>Deep Voice AI</Company>
      <Copyright>Copyright (c) 2026 Deep Voice AI</Copyright>
      <PackageProjectUrl>https://github.com/deep-voice-ai/dvai-bridge</PackageProjectUrl>
      <RepositoryUrl>https://github.com/deep-voice-ai/dvai-bridge.git</RepositoryUrl>
      <RepositoryType>git</RepositoryType>
      <PackageLicenseExpression>Apache-2.0</PackageLicenseExpression>
      <LangVersion>latest</LangVersion>
      <Nullable>enable</Nullable>
      <ImplicitUsings>enable</ImplicitUsings>
      <TreatWarningsAsErrors>true</TreatWarningsAsErrors>
      <GenerateDocumentationFile>true</GenerateDocumentationFile>
      <NoWarn>$(NoWarn);1591</NoWarn>   <!-- silence "missing xmldoc" for internal types -->
      <PublishRepositoryUrl>true</PublishRepositoryUrl>
      <EmbedUntrackedSources>true</EmbedUntrackedSources>
      <DebugType>portable</DebugType>
      <SymbolPackageFormat>snupkg</SymbolPackageFormat>
      <IncludeSymbols>true</IncludeSymbols>
    </PropertyGroup>
  </Project>
  ```
- [ ] `Directory.Packages.props` enables CPM:
  ```xml
  <Project>
    <PropertyGroup>
      <ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally>
    </PropertyGroup>
    <ItemGroup>
      <!-- Test stack -->
      <PackageVersion Include="Microsoft.NET.Test.Sdk" Version="17.13.0" />
      <PackageVersion Include="xunit" Version="2.9.2" />
      <PackageVersion Include="xunit.runner.visualstudio" Version="3.0.0" />
      <PackageVersion Include="Moq" Version="4.20.72" />
      <PackageVersion Include="coverlet.collector" Version="6.0.4" />
      <!-- Source link -->
      <PackageVersion Include="Microsoft.SourceLink.GitHub" Version="8.0.0" PrivateAssets="All" />
    </ItemGroup>
  </Project>
  ```
- [ ] `DVAIBridge.sln`: includes `src/DVAIBridge/DVAIBridge.csproj`, `src/DVAIBridge.iOS/DVAIBridge.iOS.csproj`, `src/DVAIBridge.Android/DVAIBridge.Android.csproj`, `tests/DVAIBridge.Tests/DVAIBridge.Tests.csproj`. Use `dotnet sln new` + `dotnet sln add` to keep the GUIDs canonical.
- [ ] `.gitignore`: `bin/`, `obj/`, `out/`, `*.user`, `.vs/`, `*.received.*`, `src/DVAIBridge.iOS/native/build/`, `src/DVAIBridge.iOS/native/*.xcframework`.

**Acceptance:** `pnpm install` (workspace level) recognizes the new package directory; `dotnet restore` inside `packages/dvai-bridge-dotnet/` resolves clean against an empty solution; `dotnet build` exits 0 (with no projects yet, build is a no-op).

---

## Task 2: Public C# types — records + enums + exception hierarchy ✅

**Files:**
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge/DVAIBridge.csproj`
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge/BackendKind.cs`
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge/StartOptions.cs`
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge/BoundServer.cs`
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge/StatusInfo.cs`
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge/DownloadOptions.cs`
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge/DownloadResult.cs`
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge/DVAIBridgeException.cs`
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge/ProgressEvent.cs`
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge/DVAIBridgeState.cs`

- [ ] `DVAIBridge.csproj`:
  ```xml
  <Project Sdk="Microsoft.NET.Sdk">
    <PropertyGroup>
      <TargetFramework>net10.0</TargetFramework>
      <PackageId>DVAIBridge</PackageId>
      <Description>Local-LLM bridge with OpenAI-compatible HTTP server for .NET MAUI / Avalonia / WinUI on iOS + Android.</Description>
      <PackageTags>llm;ai;openai;ios;android;maui;avalonia;winui;local-inference</PackageTags>
      <PackageReadmeFile>README.md</PackageReadmeFile>
    </PropertyGroup>
    <ItemGroup>
      <None Include="../../README.md" Pack="true" PackagePath="\" />
    </ItemGroup>
  </Project>
  ```
- [ ] `BackendKind.cs`: 7-value enum (`Auto = 0`, `Llama`, `Foundation`, `CoreML`, `MLX`, `MediaPipe`, `LiteRT`). Add `BackendKindExtensions.ToWireString()` / `BackendKindExtensions.FromWireString(string)` for round-trip with the native bindings (lowercase string match: `"auto"`, `"llama"`, etc.).
- [ ] `StartOptions.cs`: `public sealed record StartOptions { ... }` with init-only properties for all 17 fields from Phase 3C/3D (`ModelPath`, `TokenizerPath`, `MmprojPath`, `ContextSize`, `Threads`, `GpuLayers`, `HttpBasePort`, `HttpMaxPortAttempts`, `CorsOrigin`, `Temperature`, `TopP`, `TopK`, `MaxNewTokens`, `ModelId`, `Backend` (required), `EmbeddingMode`, `VisionEnabled`). Optional fields are nullable; primary constructor with `Backend` required.
- [ ] `BoundServer.cs`: `public sealed record BoundServer(string BaseUrl, int Port, BackendKind Backend, string ModelId);`.
- [ ] `StatusInfo.cs`: `public sealed record StatusInfo(bool Running, string? BaseUrl, int? Port, BackendKind? Backend, string? ModelId);`.
- [ ] `DownloadOptions.cs`: `public sealed record DownloadOptions(string Url, string Sha256, string? DestFilename = null);`.
- [ ] `DownloadResult.cs`: `public sealed record DownloadResult(string Path, string Sha256, long SizeBytes);`.
- [ ] `DVAIBridgeException.cs`: a sealed exception hierarchy:
  ```csharp
  public sealed class DVAIBridgeException : Exception
  {
      public DVAIBridgeErrorKind Kind { get; }
      public IReadOnlyDictionary<string, object?> Details { get; }
      // private ctor + static factories for each Kind:
      public static DVAIBridgeException AlreadyStarted(BackendKind backend, string baseUrl) => ...
      public static DVAIBridgeException ConfigurationInvalid(string reason) => ...
      public static DVAIBridgeException ModelLoadFailed(string reason) => ...
      public static DVAIBridgeException BackendUnavailable(BackendKind backend, string reason) => ...
      public static DVAIBridgeException BackendError(string underlying) => ...
      public static DVAIBridgeException ChecksumMismatch(string expected, string got) => ...
      public static DVAIBridgeException DownloadFailed(string reason) => ...
  }
  public enum DVAIBridgeErrorKind { AlreadyStarted, ConfigurationInvalid, ModelLoadFailed, BackendUnavailable, BackendError, ChecksumMismatch, DownloadFailed }
  ```
- [ ] `ProgressEvent.cs`: `public enum ProgressKind { Started, Progress, Completed, Failed }`, `public enum ProgressPhase { Start, Stop, Download, Load, Ready, Verify, Error }`, immutable `public sealed record ProgressEvent(ProgressKind Kind, ProgressPhase Phase, double? Percent, string? Message, string? ErrorKind, string? ErrorMessage);`.
- [ ] `DVAIBridgeState.cs`: `public sealed record DVAIBridgeState(bool IsReady, string? BaseUrl, int? Port, BackendKind? Backend, string? ModelId, DVAIBridgeException? LastError);`.
- [ ] xmldoc on every public type — `<summary>`, `<param>`, `<remarks>` where useful. `<TreatWarningsAsErrors>` + `<GenerateDocumentationFile>` from Task 1 forces this.

**Acceptance:** `dotnet build src/DVAIBridge` exits 0 with no warnings. xmldoc completeness verified by `<NoWarn>` not silencing CS1591 on this csproj — every public member has a doc comment.

---

## Task 3: Internal `INativeBridge` interface + facade `DVAIBridge` class ✅

**Files:**
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge/INativeBridge.cs`
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge/PlatformBridgeFactory.cs`
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge/DVAIBridge.cs`

- [ ] `INativeBridge.cs` (`internal` access):
  ```csharp
  internal interface INativeBridge
  {
      Task<BoundServer> StartAsync(StartOptions opts, CancellationToken ct);
      Task StopAsync(CancellationToken ct);
      Task<StatusInfo> GetStatusAsync(CancellationToken ct);
      Task<DownloadResult> DownloadModelAsync(DownloadOptions opts, CancellationToken ct);
      // Push-side: returns an IDisposable that unregisters when disposed.
      IDisposable SubscribeProgress(Action<ProgressEvent> handler);
  }
  ```
- [ ] `PlatformBridgeFactory.cs` (`internal`): `static INativeBridge Create()` — returns `IOSNativeBridge` on iOS, `AndroidNativeBridge` on Android, `UnsupportedPlatformBridge` (throws BackendUnavailable on every call) elsewhere. Uses `OperatingSystem.IsIOS()` / `IsAndroid()` for the runtime gate; uses runtime-loaded type lookup (`Type.GetType("DVAIBridge.iOS.IOSNativeBridge, DVAIBridge.iOS")`) so the facade csproj doesn't have a hard reference to the platform slices (the slices instead hard-reference the facade).
- [ ] `DVAIBridge.cs` — the public facade:
  ```csharp
  public sealed class DVAIBridge : IAsyncDisposable
  {
      private static readonly Lazy<DVAIBridge> _shared = new(() => new DVAIBridge(PlatformBridgeFactory.Create()));
      public static DVAIBridge Shared => _shared.Value;

      private readonly INativeBridge _bridge;
      private readonly Channel<ProgressEvent> _progress = Channel.CreateUnbounded<ProgressEvent>(
          new UnboundedChannelOptions { SingleReader = false, SingleWriter = true, AllowSynchronousContinuations = false });
      private readonly IDisposable _progressSubscription;

      internal DVAIBridge(INativeBridge bridge)
      {
          _bridge = bridge;
          _progressSubscription = bridge.SubscribeProgress(ev => _progress.Writer.TryWrite(ev));
      }

      public async Task<BoundServer> StartAsync(StartOptions opts, CancellationToken ct = default) { ... }
      public Task StopAsync(CancellationToken ct = default) => _bridge.StopAsync(ct);
      public Task<StatusInfo> GetStatusAsync(CancellationToken ct = default) => _bridge.GetStatusAsync(ct);
      public Task<DownloadResult> DownloadModelAsync(DownloadOptions opts, CancellationToken ct = default) => _bridge.DownloadModelAsync(opts, ct);

      public IAsyncEnumerable<ProgressEvent> ProgressEvents => GetProgressEventsAsync();
      public async IAsyncEnumerable<ProgressEvent> GetProgressEventsAsync(
          [EnumeratorCancellation] CancellationToken ct = default)
      {
          await foreach (var ev in _progress.Reader.ReadAllAsync(ct).ConfigureAwait(false))
              yield return ev;
      }

      public async ValueTask<DVAIBridgeState> GetStateAsync(CancellationToken ct = default) { ... }

      public ValueTask DisposeAsync()
      {
          _progressSubscription.Dispose();
          _progress.Writer.TryComplete();
          return ValueTask.CompletedTask;
      }
  }
  ```
- [ ] `StartAsync` implementation: cross-platform `BackendKind` validation per spec §3.5; catches `INativeBridge`-thrown `DVAIBridgeException` and rethrows; wraps unexpected exceptions as `BackendError`.
- [ ] `[InternalsVisibleTo("DVAIBridge.iOS")]`, `[InternalsVisibleTo("DVAIBridge.Android")]`, `[InternalsVisibleTo("DVAIBridge.Tests")]` on the facade assembly.

**Acceptance:** `dotnet build src/DVAIBridge` exits 0; the facade's public surface compiles against the type definitions from Task 2 and the (yet-to-exist) iOS/Android slices via the runtime-loaded `Type.GetType` indirection (so a missing slice at compile time isn't a build error — it's a runtime "BackendUnavailable" error). CI confirms the cross-platform-fail path runs cleanly on Windows.

---

## Task 4: Native iOS Swift `@objc` wrapper + xcframework build script ✅

**Files:**
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge.iOS/native/Package.swift`
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge.iOS/native/Sources/DVAIBridgeNetBridge/DVAIBridgeNetBridge.swift`
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge.iOS/native/build-xcframework.sh`
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge.iOS/native/.gitignore`

- [ ] `Package.swift` declares a SwiftPM package `DVAIBridgeNetBridge` with a single library target depending on `DVAIBridge` (Phase 3C v2.3) via path or git revision:
  ```swift
  // swift-tools-version:5.9
  import PackageDescription
  let package = Package(
      name: "DVAIBridgeNetBridge",
      platforms: [.iOS(.v15_1)],
      products: [
          .library(name: "DVAIBridgeNetBridge", type: .static, targets: ["DVAIBridgeNetBridge"])
      ],
      dependencies: [
          .package(name: "DVAIBridge", path: "../../../../dvai-bridge-ios"),
      ],
      targets: [
          .target(name: "DVAIBridgeNetBridge", dependencies: [
              .product(name: "DVAIBridge", package: "DVAIBridge"),
          ])
      ]
  )
  ```
- [ ] `DVAIBridgeNetBridge.swift`: a single `@objc(DVAIBridgeNetBridge) public final class` subclass of `NSObject` with:
  - `@objc public static let shared = DVAIBridgeNetBridge()`
  - `@objc public func start(config: NSDictionary, completion: @escaping (NSDictionary?, NSError?) -> Void)` — opens `Task { try await DVAIBridge.shared.start(...) }`, marshals to NSDictionary, calls completion.
  - Same shape for `stop`, `status`, `downloadModel`.
  - `@objc public func subscribeProgress(onEvent: @escaping (NSDictionary) -> Void) -> NSObject` — wraps `DVAIBridge.shared.progressPublisher` (Combine) into an `AnyCancellable` returned as `NSObject`. Consumer calls `cancellable.invalidate()` (a no-op on `AnyCancellable` directly; we wrap in a tiny `@objc` `CancellableHandle` class with an explicit `cancel()` method).
  - Translation helpers: `NSDictionary → DVAIBridgeConfig`, `BoundServer → NSDictionary`, `DVAIBridgeError → NSError` (domain `"co.deepvoiceai.bridge"`, userInfo with `kind` + `details`).
- [ ] `build-xcframework.sh`:
  ```bash
  #!/usr/bin/env bash
  set -euo pipefail
  cd "$(dirname "$0")"
  rm -rf build *.xcframework
  for SDK in iphoneos iphonesimulator; do
    swift build -c release --sdk "$SDK" --triple ...   # actually use xcodebuild with -scheme
  done
  # Use xcodebuild archive + xcodebuild -create-xcframework
  xcodebuild -create-xcframework \
    -framework build/Release-iphoneos/DVAIBridgeNetBridge.framework \
    -framework build/Release-iphonesimulator/DVAIBridgeNetBridge.framework \
    -output DVAIBridgeNetBridge.xcframework
  ```
  (Fill in the actual xcodebuild invocations; SwiftPM-only doesn't produce a framework, so the script wraps the SwiftPM target in an Xcode project at build time. Reference Phase 3C's existing xcframework script.)
- [ ] Decide whether the xcframework is committed or generated:
  - **Decision: generated by CI**, gitignored. Build artifact, not source.
  - The `DVAIBridge.iOS.csproj` (Task 5) references it via `<NativeReference Include="native/DVAIBridgeNetBridge.xcframework">`; the CI workflow runs `build-xcframework.sh` before `dotnet pack`.
- [ ] Verify the @objc surface roundtrips every BackendKind value, every error Kind, and every ProgressPhase via NSDictionary keys. Document the wire format in a comment block at the top of `DVAIBridgeNetBridge.swift`.

**Acceptance:** Running `bash build-xcframework.sh` on a macos-latest runner produces `DVAIBridgeNetBridge.xcframework` with both device + simulator slices. The xcframework's Info.plist lists `DVAIBridgeNetBridge` as the framework name and `15.1` as the minimum iOS version.

---

## Task 5: iOS bindings csproj + ApiDefinition.cs + IOSNativeBridge.cs ✅

**Files:**
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge.iOS/DVAIBridge.iOS.csproj`
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge.iOS/ApiDefinition.cs`
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge.iOS/StructsAndEnums.cs`
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge.iOS/IOSNativeBridge.cs`

- [ ] `DVAIBridge.iOS.csproj`:
  ```xml
  <Project Sdk="Microsoft.NET.Sdk">
    <PropertyGroup>
      <TargetFramework>net10.0-ios18.0</TargetFramework>
      <SupportedOSPlatformVersion>15.1</SupportedOSPlatformVersion>
      <IsBindingProject>true</IsBindingProject>
      <PackageId>DVAIBridge.iOS</PackageId>
      <Description>iOS native bindings for DVAIBridge — internal slice of DVAIBridge NuGet family.</Description>
      <PackageTags>llm;ai;ios;binding;internal</PackageTags>
      <NoBindingEmbedding>false</NoBindingEmbedding>
    </PropertyGroup>
    <ItemGroup>
      <ObjcBindingApiDefinition Include="ApiDefinition.cs" />
      <ObjcBindingCoreSource Include="StructsAndEnums.cs" />
      <NativeReference Include="native/DVAIBridgeNetBridge.xcframework">
        <Kind>Framework</Kind>
        <SmartLink>True</SmartLink>
        <ForceLoad>True</ForceLoad>
      </NativeReference>
      <ProjectReference Include="../DVAIBridge/DVAIBridge.csproj" />
    </ItemGroup>
  </Project>
  ```
- [ ] `ApiDefinition.cs`: `[BaseType(typeof(NSObject))]` interface for `DVAIBridgeNetBridge` with `[Static, Export("shared")]` singleton getter and `[Async] [Export("start:completion:")]`-style methods. Use Microsoft's [iOS bindings reference](https://learn.microsoft.com/en-us/dotnet/maui/migration/ios-binding-projects) for the attribute syntax. Include the `subscribeProgress:` method bound as `IDisposable Subscribe(Action<NSDictionary> onEvent)` (using `[Export]` + manual translation in `IOSNativeBridge`).
- [ ] `StructsAndEnums.cs`: empty placeholder — we don't bind any C structs (the wrapper takes NSDictionary). May add `BackendKind` mirror enum for compile-time clarity, but not required.
- [ ] `IOSNativeBridge.cs` (`internal sealed class IOSNativeBridge : INativeBridge`):
  - Implements every `INativeBridge` method by:
    1. Marshalling C# records → `NSDictionary` (via a small `NSDictionaryExtensions` helper).
    2. Awaiting the bound `[Async]` C# method (e.g. `await Native.DVAIBridgeNetBridge.Shared.StartAsync(dict)`).
    3. Marshalling `NSDictionary` response → C# record.
    4. Catching `NSErrorException` → mapping to `DVAIBridgeException` via the `kind` userInfo key.
  - `SubscribeProgress(Action<ProgressEvent> handler)` calls the bound `subscribeProgress:` method with a closure that maps `NSDictionary` → `ProgressEvent` and invokes `handler`. Returns the `IDisposable` wrapping the bound `CancellableHandle`'s `cancel()` call.
- [ ] `[assembly: System.Runtime.CompilerServices.InternalsVisibleTo("DVAIBridge.Tests")]`.

**Acceptance:** `dotnet build src/DVAIBridge.iOS -c Release` exits 0 on a macos-latest runner with the .NET 10 iOS workload installed and the xcframework present. `dotnet pack src/DVAIBridge.iOS -c Release` produces a `.nupkg` ~3.5 MB containing the xcframework + the binding DLL.

---

## Task 6: Android bindings csproj + Transforms/Metadata.xml + AndroidNativeBridge.cs ✅

**Files:**
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge.Android/DVAIBridge.Android.csproj`
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge.Android/Transforms/Metadata.xml`
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge.Android/Transforms/EnumFields.xml`
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge.Android/AndroidNativeBridge.cs`
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge.Android/native/.gitkeep` (placeholder for optional shim)

- [ ] `DVAIBridge.Android.csproj`:
  ```xml
  <Project Sdk="Microsoft.NET.Sdk">
    <PropertyGroup>
      <TargetFramework>net10.0-android36.0</TargetFramework>
      <SupportedOSPlatformVersion>24</SupportedOSPlatformVersion>
      <IsBindingProject>true</IsBindingProject>
      <AndroidClassParser>class-parse</AndroidClassParser>
      <AndroidCodegenTarget>XAJavaInterop1</AndroidCodegenTarget>
      <PackageId>DVAIBridge.Android</PackageId>
      <Description>Android native bindings for DVAIBridge — internal slice of DVAIBridge NuGet family.</Description>
      <PackageTags>llm;ai;android;binding;internal</PackageTags>
    </PropertyGroup>
    <ItemGroup>
      <!-- AAR pulled at consumer build time via AndroidMavenLibrary in consumer csproj.
           For binding generation, we need the AAR locally — fetched by CI before build. -->
      <AndroidLibrary Include="native/dvai-bridge-2.4.0.aar">
        <Bind>true</Bind>
      </AndroidLibrary>
      <TransformFile Include="Transforms/Metadata.xml" />
      <TransformFile Include="Transforms/EnumFields.xml" />
      <ProjectReference Include="../DVAIBridge/DVAIBridge.csproj" />
    </ItemGroup>
  </Project>
  ```
- [ ] CI fetches the AAR pre-build:
  ```bash
  curl -L -u "$GITHUB_USER:$GITHUB_TOKEN" \
    "https://maven.pkg.github.com/deep-voice-ai/dvai-bridge/co/deepvoiceai/dvai-bridge/2.4.0/dvai-bridge-2.4.0.aar" \
    -o native/dvai-bridge-2.4.0.aar
  ```
- [ ] `Transforms/Metadata.xml`:
  ```xml
  <metadata>
    <!-- Rename the Java-bound Kotlin object to NativeDVAIBridge to avoid C# name collision. -->
    <attr path="/api/package[@name='co.deepvoiceai.bridge']/class[@name='DVAIBridge']"
          name="managedName">NativeDVAIBridge</attr>
    <!-- suspend fun → Task<T> conversions. The .NET 10 Android binding generator handles
         this automatically when the @TaskAdaption annotation is present on the Kotlin side;
         since the Phase 3D AAR doesn't carry that annotation, force the conversion here. -->
    <attr path="/api/package[@name='co.deepvoiceai.bridge']/class[@name='NativeDVAIBridge']/method[@name='start']"
          name="managedReturn">System.Threading.Tasks.Task&lt;Co.Deepvoiceai.Bridge.BoundServer&gt;</attr>
    <!-- Repeat for stop, status, downloadModel. -->
  </metadata>
  ```
- [ ] `Transforms/EnumFields.xml`: empty unless the AAR's `BackendKind` Kotlin enum auto-binds with non-idiomatic field names; in that case, force-rename to PascalCase here.
- [ ] `AndroidNativeBridge.cs` (`internal sealed class AndroidNativeBridge : INativeBridge`):
  - Implements every `INativeBridge` method by calling the bound `Co.Deepvoiceai.Bridge.NativeDVAIBridge.Start(...)` etc. and translating the bound types (`Co.Deepvoiceai.Bridge.BoundServer`, `Co.Deepvoiceai.Bridge.StatusInfo`, …) to public C# records.
  - `SubscribeProgress(Action<ProgressEvent> handler)` consumes the bound `Flow<ProgressEvent>`. The naive bound `IFlow` interface is awkward; we collect via a Kotlin extension that converts `Flow<ProgressEvent>` to a callback subscription. **Empirical decision point**: if the binding generator's `IFlow` C# wrapper works well, no shim needed. If not, add `native/DVAIBridgeAndroidShim.kt` with a `subscribe(listener: Consumer<ProgressEvent>): AutoCloseable` method, build it as a thin AAR alongside (or merged with) the umbrella, and bind that instead. Default branch: try `IFlow` first, fall back to shim only if necessary.
  - Catches Java exceptions → maps to `DVAIBridgeException`. Phase 3D's `DVAIBridgeError` Kotlin sealed class becomes a hierarchy of bound C# subclasses; map each `Co.Deepvoiceai.Bridge.DVAIBridgeError.AlreadyStarted` → `DVAIBridgeException.AlreadyStarted(...)` etc.
- [ ] First Android binding regenerate (`dotnet build` with verbose output) reveals what the auto-generated API looks like; iterate on `Metadata.xml` until the C# surface is clean. Mark the iteration as a sub-task of Task 6 — expect 2-3 dotnet-build cycles.
- [ ] `[assembly: InternalsVisibleTo("DVAIBridge.Tests")]`.

**Acceptance:** `dotnet build src/DVAIBridge.Android -c Release` exits 0 on an ubuntu-latest runner with the .NET 10 Android workload installed and the AAR fetched. Generated obj/ contains a clean `Co.Deepvoiceai.Bridge.NativeDVAIBridge` C# wrapper with `Task<BoundServer> StartAsync(StartOptionsMessage)` shape. `dotnet pack` produces a `.nupkg` ~50 KB (binding DLL + transform XML; AAR is not bundled — it's fetched by the consumer at consumer-build time).

---

## Task 7: Phase 3D Android AAR republish at 2.4.0 ✅

**Files:**
- Update: `packages/dvai-bridge-android/android/gradle.properties` — `dvaiBridgeVersion=2.4.0` (bump from 2.3.0)
- Update: `packages/dvai-bridge-android/android/build.gradle` — bump publish version
- Update: `packages/dvai-bridge-android/CHANGELOG.md` — note "republish at 2.4.0 alongside Phase 3G .NET NuGet; no source changes"

- [ ] No Kotlin source changes; this is a build-graph alignment.
- [ ] CI re-runs the existing Android publish workflow at `v2.4.0` to push the new AAR artifact to GitHub Packages Maven.
- [ ] The .NET Android binding's CI-fetch URL (Task 6) references `2.4.0` so the build graph is internally consistent.

**Acceptance:** GitHub Packages shows `co.deepvoiceai:dvai-bridge:2.4.0` after the v2.4.0 tag is pushed (Task 14). The .NET Android binding's CI fetch step pulls the new artifact successfully.

---

## Task 8: Phase 3F Flutter podspec / pubspec re-confirmation ✅

This is a defensive task: confirm Phase 3F's `dvai_bridge` plugin is unaffected by the .NET work (it should be — they're in different packages, different distribution systems).

- [ ] `pnpm install` from the workspace root resolves clean.
- [ ] `flutter pub get` inside `packages/dvai-bridge-flutter/` still resolves clean.
- [ ] No Phase 3F source changes; if `scripts/sync-versions.js` (extended in Task 1 / Task 14) tries to bump `dvai_bridge`'s pubspec version, manually exclude it (`dvai_bridge` stays at 2.3.0 since 3G is additive and doesn't touch Flutter).
- [ ] Document the intentional 2.3 → 2.4 jump for .NET-only in `docs/migration/v2.3-to-v2.4.md`.

**Acceptance:** Flutter package's `flutter analyze` + `flutter test` still pass at the previous commit's HEAD. No spurious Flutter changes in the v2.4.0 commit.

---

## Task 9: xUnit unit tests on facade with mocked INativeBridge ✅

**Files:**
- Create: `packages/dvai-bridge-dotnet/tests/DVAIBridge.Tests/DVAIBridge.Tests.csproj`
- Create: `packages/dvai-bridge-dotnet/tests/DVAIBridge.Tests/DVAIBridgeFacadeTests.cs`
- Create: `packages/dvai-bridge-dotnet/tests/DVAIBridge.Tests/BackendKindValidationTests.cs`
- Create: `packages/dvai-bridge-dotnet/tests/DVAIBridge.Tests/ProgressEventStreamTests.cs`
- Create: `packages/dvai-bridge-dotnet/tests/DVAIBridge.Tests/PlatformExceptionMappingTests.cs`
- Create: `packages/dvai-bridge-dotnet/tests/DVAIBridge.Tests/Fakes/FakeNativeBridge.cs`

- [ ] `DVAIBridge.Tests.csproj`:
  ```xml
  <Project Sdk="Microsoft.NET.Sdk">
    <PropertyGroup>
      <TargetFramework>net10.0</TargetFramework>
      <IsPackable>false</IsPackable>
    </PropertyGroup>
    <ItemGroup>
      <PackageReference Include="Microsoft.NET.Test.Sdk" />
      <PackageReference Include="xunit" />
      <PackageReference Include="xunit.runner.visualstudio" />
      <PackageReference Include="Moq" />
      <PackageReference Include="coverlet.collector" />
      <ProjectReference Include="../../src/DVAIBridge/DVAIBridge.csproj" />
    </ItemGroup>
  </Project>
  ```
- [ ] `Fakes/FakeNativeBridge.cs`: implements `INativeBridge` with configurable behavior (canned return values, scripted exception throws, scripted progress event sequences). Used by every test.
- [ ] `DVAIBridgeFacadeTests.cs`:
  - `StartAsync` forwards `StartOptions` to `_bridge.StartAsync` and returns the resulting `BoundServer`.
  - `StopAsync` calls `_bridge.StopAsync` once.
  - `GetStateAsync` returns a `DVAIBridgeState` derived from `_bridge.GetStatusAsync`.
  - `DownloadModelAsync` happy path returns the right `DownloadResult`.
  - `DisposeAsync` cancels the progress subscription and completes the channel.
- [ ] `BackendKindValidationTests.cs`:
  - On (synthetic) iOS, requesting `BackendKind.MediaPipe` throws `DVAIBridgeException(Kind: BackendUnavailable)`.
  - On (synthetic) Android, requesting `BackendKind.Foundation` throws `DVAIBridgeException(Kind: BackendUnavailable)`.
  - On (synthetic) Windows, requesting any backend throws `BackendUnavailable` with the "no native binding for this platform" reason.
  - `BackendKind.Auto` is accepted on every platform.
  - **Note**: `OperatingSystem.IsIOS()` etc. are not directly mockable. Use a thin `IOperatingSystemAdapter` injected via the test-seam constructor (or `[InternalsVisibleTo]` + a static settable `OS_OVERRIDE` field on `PlatformBridgeFactory` with `[ThreadStatic]` for test isolation).
- [ ] `ProgressEventStreamTests.cs`:
  - Feed the fake bridge a sequence of progress events; `await foreach (var ev in bridge.ProgressEvents)` yields them in order.
  - Cancellation via `WithCancellation(ct)` exits the loop cleanly without closing the underlying channel.
  - Multiple concurrent `await foreach` consumers each receive every event (broadcast semantics — verify the channel config supports this; if `Channel.CreateUnbounded` doesn't fan out, switch to a custom multicast wrapper or use `System.Reactive.Linq.Subject<T>` internally with a single `IAsyncEnumerable<T>` adapter via `Reactive.Linq.AsyncEnumerable.ToAsyncEnumerable`. Decision: prototype during this task; if multicast is non-trivial, document "single-consumer" semantics and revisit in 2.5).
- [ ] `PlatformExceptionMappingTests.cs`:
  - Fake bridge throws `DVAIBridgeException.AlreadyStarted(...)` from `StartAsync` → facade rethrows unchanged.
  - Fake bridge throws an arbitrary `Exception("network down")` from `DownloadModelAsync` → facade wraps as `DVAIBridgeException.BackendError("network down")`.
  - Every error Kind round-trips its `Details` dictionary keys.

**Acceptance:** `dotnet test` runs all tests green. Coverage of the facade ≥ 85% (xUnit + Coverlet). CI's coverage report uploaded as a build artifact (Task 12).

---

## Task 10: Docs — `dotnet-sdk.md` + migration entry + sidebar ✅

**Files:**
- Create: `docs/guide/dotnet-sdk.md`
- Create: `docs/migration/v2.3-to-v2.4.md`
- Update: `docs/.vitepress/config.ts` (sidebar add .NET SDK page below Flutter; add v2.3→v2.4 migration entry)

- [ ] `dotnet-sdk.md` mirrors the structure of `flutter-sdk.md`:
  - Install (`dotnet add package DVAIBridge --version 2.4.0`)
  - .NET 10 prerequisite + workload install (`dotnet workload install ios android maui`)
  - iOS prerequisites (no extra config — xcframework is bundled in the NuGet)
  - Android prerequisites (`<AndroidMavenLibrary>` repo entry in consumer csproj + nuget.config with GH PAT)
  - Quickstart (the §3.2 spec snippet, expanded into a runnable .NET MAUI page-behind code)
  - BackendKind table + platform availability
  - `IAsyncEnumerable<ProgressEvent>` example (`await foreach`)
  - Conversion-to-`IObservable` snippet for Rx-favoring consumers (one-line `.ToObservable()` import)
  - MAUI ContentPage example using `IAsyncEnumerable.ForEachAsync` from `System.Linq.Async`
  - Error reference table — `DVAIBridgeException.Kind` ↔ what it means ↔ recovery hint
  - MLX-under-CocoaPods caveat — iOS section: "MLX backend not available under CocoaPods consumers; not applicable to .NET (we ship xcframework)"
  - WinUI / Avalonia / desktop note — runtime-fail with `BackendUnavailable`; Phase 4 candidate
  - NuGet.org distribution note (asymmetry vs the rest of the family)
- [ ] `v2.3-to-v2.4.md`: short migration note. Most users add a new package (`dotnet add package DVAIBridge`); existing iOS/Android/RN/Flutter users see no change. Note the AAR republish at 2.4.0 (Task 7) and the NuGet.org distribution.
- [ ] Sidebar: add ".NET SDK" under "Native SDKs" group below Flutter SDK.

**Acceptance:** `pnpm run docs:dev` renders the new page; no broken links; `pnpm run docs:build` exits 0. The .NET SDK page links forward to NuGet.org and back to `docs/guide/ios-native-sdk.md` for the underlying SDK details.

---

## Task 11: CI workflow ✅

**Files:**
- Create: `.github/workflows/test-dotnet.yml`

- [ ] Steps:
  1. checkout
  2. setup .NET 10 SDK (matrix: 10.0.7 LTS-current — single version; no multi-target)
  3. install workloads: `dotnet workload install ios android` on macos-latest; `dotnet workload install android` on ubuntu-latest
  4. (macOS only) build the iOS Swift xcframework: `bash src/DVAIBridge.iOS/native/build-xcframework.sh`
  5. (Linux + macOS) fetch the Phase 3D AAR (`curl -L -u … 2.4.0/dvai-bridge-2.4.0.aar`) into `src/DVAIBridge.Android/native/`. Skip if a prior commit already did this in cache.
  6. `dotnet restore` at the solution root
  7. (macOS) `dotnet build src/DVAIBridge.iOS -c Release` (separate; needs Xcode)
  8. (Linux + macOS) `dotnet build src/DVAIBridge.Android -c Release`
  9. (Linux + macOS) `dotnet build src/DVAIBridge -c Release` + `dotnet test tests/DVAIBridge.Tests -c Release --collect:"XPlat Code Coverage"`
  10. (macOS only, on tag) `dotnet pack -c Release -o ./out` for all three csprojs → uploads `.nupkg` + `.snupkg` artifacts
  11. (macOS only, on tag) `dotnet nuget push ./out/*.nupkg --source https://api.nuget.org/v3/index.json --api-key ${{ secrets.NUGET_API_KEY }} --skip-duplicate` — guarded by tag-push trigger only
- [ ] Matrix: `os: [ubuntu-latest, macos-latest]`. Linux runs the facade + Android slice + tests; macos runs the iOS slice + the macOS pack/push job.
- [ ] Cache `~/.nuget/packages` and `obj/` per-os to speed up repeat builds.
- [ ] Upload coverage report as a build artifact for inspection.

**Acceptance:** A test PR triggers the workflow; build + test + dry-run pack steps pass on both runners. The `dotnet pack` step on macos-latest produces three `.nupkg` files and one `.snupkg` per package. On a `v2.4.0` tag push, the `dotnet nuget push` step uploads to NuGet.org without errors.

---

## Task 12: Sync-versions / sync-package-meta extension ✅

**Files:**
- Update: `scripts/sync-versions.js`
- Update: `scripts/sync-package-meta.js`

- [ ] `sync-versions.js`: add a handler for `Directory.Build.props` (regex on `<Version>2.3.0</Version>` → `<Version>2.4.0</Version>`). Path: `packages/dvai-bridge-dotnet/Directory.Build.props`.
- [ ] `sync-package-meta.js`: add a handler that copies `description` / `keywords` / `author` from `package.json` into the three csprojs' `<Description>` / `<PackageTags>` / `<Authors>` MSBuild properties (via Directory.Build.props or per-csproj — choose Directory.Build.props for centralization).
- [ ] Add a verification step: `node scripts/verify-cap-sync.sh` (or similar) confirms `package.json.version === Directory.Build.props.<Version>` on every commit. Extend the existing Phase 3D-3F verification harness.

**Acceptance:** Running `node scripts/sync-versions.js 2.4.0` updates `Directory.Build.props` and every other tracked file in one pass. `node scripts/sync-package-meta.js` updates the .NET csproj metadata in lockstep with the .NET package's `package.json`.

---

## Task 13: Defer-list verification (no .NET-related deferrals leaked into other phases) ✅

This is a one-shot audit task before tag.

- [ ] Grep `docs/superpowers/specs/` and `docs/superpowers/plans/` for any TODO / FIXME / "deferred to 3G" markers in earlier phase docs. Resolve or remove.
- [ ] Audit: are there any tasks in Phase 3F's plan (or earlier) that should have addressed a .NET concern but didn't? Spot-check `2026-04-27-phase3f-flutter-package.md`. If anything is "we'll do this in 3G" → either fold it into Task 4-9 above or document explicitly as out-of-scope (Phase 4).
- [ ] Update Phase 3 foundation spec (`docs/superpowers/specs/2026-04-26-phase3-foundation-design.md`) to mark Phase 3G complete in the sub-phase position diagram.

**Acceptance:** Grep `docs/superpowers/` for `3G` / `dotnet` / `nuget` / `MAUI` returns hits only in this plan, the matching spec, the migration guide, and the foundation diagram update.

---

---

## Rev 2 tasks (14–26) — desktop + ONNX + ML.NET expansion

> **Branch**: `feat/phase3g-rev2-desktop-onnx-mlnet` (separate from the rev 1 implementation branch; merge order is rev 1 first, rev 2 on top — see Task 26).

## Task 14: Mac Catalyst slice — multi-target TFM in `DVAIBridge.iOS.csproj`

**Why**: free-reuse expansion — the Phase 3C SwiftPM package already supports `.macCatalyst(.v15_1)`, the `@objc` Swift wrapper compiles against Catalyst with zero source changes, and `xcodebuild -create-xcframework` emits a Catalyst slice alongside the iOS device + simulator slices. One csproj edit + xcframework build script tweak unlocks .NET MAUI Mac Catalyst consumers (a common shape for "I want my MAUI iOS app to also run on macOS as a Catalyst app").

**Files:**
- Update: `packages/dvai-bridge-dotnet/src/DVAIBridge.iOS/DVAIBridge.iOS.csproj` — change `<TargetFramework>net10.0-ios18.0</TargetFramework>` to `<TargetFrameworks>net10.0-ios18.0;net10.0-maccatalyst18.0</TargetFrameworks>` + per-TFM `<SupportedOSPlatformVersion>15.1</SupportedOSPlatformVersion>`.
- Update: `packages/dvai-bridge-dotnet/src/DVAIBridge.iOS/native/build-xcframework.sh` — add a third `xcodebuild archive` invocation for `-destination "generic/platform=macOS,variant=Mac Catalyst"`, then include the resulting `*-maccatalyst.framework` in the `xcodebuild -create-xcframework` step.
- Update: `packages/dvai-bridge-dotnet/src/DVAIBridge/PlatformBridgeFactory.cs` — add `OperatingSystem.IsMacCatalyst()` branch that routes to `IOSNativeBridge` (same instance class).
- Update: `.github/workflows/test-dotnet.yml` — add `dotnet build src/DVAIBridge.iOS -f net10.0-maccatalyst18.0 -c Release` step on the macos-latest job.

- [ ] Confirm via `xcodebuild -showsdks` on macos-latest CI runner that `macosx16.x` SDK + Catalyst SDK are available in the default Xcode toolchain (Xcode 16+ ships with Catalyst).
- [ ] Modify `build-xcframework.sh` to produce three archives: `iphoneos`, `iphonesimulator`, and Catalyst (use `xcodebuild archive -scheme DVAIBridgeNetBridge -destination "generic/platform=macOS,variant=Mac Catalyst" -archivePath build/maccatalyst.xcarchive SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES`).
- [ ] `xcodebuild -create-xcframework` with three `-framework <archive>/Products/Library/Frameworks/DVAIBridgeNetBridge.framework` flags.
- [ ] Verify the resulting xcframework's `Info.plist` lists three `AvailableLibraries` entries with the expected SupportedPlatforms keys (`ios`, `ios+iossimulator`, `macos+maccatalyst`).
- [ ] Multi-target csproj builds clean on both TFMs: `dotnet build src/DVAIBridge.iOS -f net10.0-ios18.0 -c Release` and `dotnet build src/DVAIBridge.iOS -f net10.0-maccatalyst18.0 -c Release`.
- [ ] Update facade nuspec dep group: add `<group targetFramework="net10.0-maccatalyst18.0"><dependency id="DVAIBridge.iOS" version="[2.4.0]" /></group>`.
- [ ] Add a Catalyst-platform branch to `BackendKindValidationTests.cs`: on Catalyst, iOS-only backends (`Foundation`, `CoreML`, `MLX`) are accepted (same as iOS); Android-only backends are rejected.

**Acceptance**: `dotnet pack src/DVAIBridge.iOS -c Release` produces a single `.nupkg` with both `lib/net10.0-ios18.0/` and `lib/net10.0-maccatalyst18.0/` folders. A test consumer csproj targeting `net10.0-maccatalyst18.0` resolves the dependency cleanly. Catalyst's xcframework slice loads at runtime in a smoke MAUI Catalyst app.

**Effort**: 0.5 day.

---

## Task 15: Desktop slice scaffold + RID-keyed `llama.cpp` native fetch

**Files:**
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge.Desktop/DVAIBridge.Desktop.csproj`
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge.Desktop/scripts/fetch-llama-binaries.sh`
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge.Desktop/scripts/verify-llama-checksums.sh`
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge.Desktop/scripts/llama-checksums.txt`
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge.Desktop/.gitignore` (ignore `runtimes/`)
- Update: `packages/dvai-bridge-dotnet/DVAIBridge.sln` (add `DVAIBridge.Desktop.csproj`)
- Update: `packages/dvai-bridge-dotnet/Directory.Packages.props` (add `Microsoft.AspNetCore.App` framework reference for the embedded Kestrel host)

- [ ] Pin **llama.cpp release tag `b8946`** (verified via WebFetch on https://github.com/ggerganov/llama.cpp/releases on 2026-04-27 as the latest stable). Bump cadence: re-pin on each major DVAIBridge release; intra-release we hold the tag stable so consumer-side caches stay valid.
- [ ] `DVAIBridge.Desktop.csproj`:
  ```xml
  <Project Sdk="Microsoft.NET.Sdk">
    <PropertyGroup>
      <TargetFramework>net10.0</TargetFramework>
      <PackageId>DVAIBridge.Desktop</PackageId>
      <Description>Desktop (Windows / macOS / Linux) Llama backend for DVAIBridge — bundles llama.cpp b8946 prebuilt natives per RID.</Description>
      <PackageTags>llm;ai;openai;windows;linux;macos;maui;avalonia;winui;llama;local-inference</PackageTags>
      <RuntimeIdentifiers>win-x64;win-arm64;osx-x64;osx-arm64;linux-x64;linux-arm64</RuntimeIdentifiers>
    </PropertyGroup>
    <ItemGroup>
      <FrameworkReference Include="Microsoft.AspNetCore.App" />
      <ProjectReference Include="../DVAIBridge/DVAIBridge.csproj" />
      <Compile Include="../shared/DVAIBridge.Shared.Hosting/*.cs" LinkBase="Shared" />
    </ItemGroup>
    <ItemGroup>
      <Content Include="runtimes/win-x64/native/llama.dll"  Pack="true" PackagePath="runtimes/win-x64/native/" />
      <Content Include="runtimes/win-arm64/native/llama.dll" Pack="true" PackagePath="runtimes/win-arm64/native/" />
      <Content Include="runtimes/osx-x64/native/libllama.dylib" Pack="true" PackagePath="runtimes/osx-x64/native/" />
      <Content Include="runtimes/osx-arm64/native/libllama.dylib" Pack="true" PackagePath="runtimes/osx-arm64/native/" />
      <Content Include="runtimes/linux-x64/native/libllama.so" Pack="true" PackagePath="runtimes/linux-x64/native/" />
      <Content Include="runtimes/linux-arm64/native/libllama.so" Pack="true" PackagePath="runtimes/linux-arm64/native/" />
      <!-- ggml.* sibling natives — repeat for each RID. -->
    </ItemGroup>
  </Project>
  ```
- [ ] `scripts/fetch-llama-binaries.sh`:
  ```bash
  #!/usr/bin/env bash
  set -euo pipefail
  TAG="b8946"
  RUNTIMES_DIR="$(cd "$(dirname "$0")/.." && pwd)/runtimes"
  declare -A ARTIFACTS=(
    [win-x64]="llama-${TAG}-bin-win-cpu-x64.zip"
    [win-arm64]="llama-${TAG}-bin-win-cpu-arm64.zip"
    [osx-x64]="llama-${TAG}-bin-macos-x64.zip"
    [osx-arm64]="llama-${TAG}-bin-macos-arm64.zip"
    [linux-x64]="llama-${TAG}-bin-ubuntu-x64.zip"
    [linux-arm64]="llama-${TAG}-bin-ubuntu-arm64.zip"
  )
  for RID in "${!ARTIFACTS[@]}"; do
    URL="https://github.com/ggerganov/llama.cpp/releases/download/${TAG}/${ARTIFACTS[$RID]}"
    mkdir -p "${RUNTIMES_DIR}/${RID}/native"
    curl -fL "$URL" -o /tmp/llama-${RID}.zip
    unzip -j /tmp/llama-${RID}.zip "*/llama.dll" "*/libllama.dylib" "*/libllama.so" "*/ggml*.{dll,dylib,so}" -d "${RUNTIMES_DIR}/${RID}/native/" 2>/dev/null || true
  done
  bash "$(dirname "$0")/verify-llama-checksums.sh"
  ```
- [ ] `scripts/llama-checksums.txt`: a SHA256 line per `runtimes/<rid>/native/<lib>` file. Generated once (during this task) by running `fetch-llama-binaries.sh` + `sha256sum runtimes/**/native/*` on a known-good macos-latest runner. Committed to source.
- [ ] `scripts/verify-llama-checksums.sh`: reads `llama-checksums.txt`, recomputes SHA256 for each file under `runtimes/`, fails if any drift. Run as a pre-pack step in CI (Task 25) to catch supply-chain / corruption issues.
- [ ] **Linux ARM64 fallback**: if upstream `llama.cpp` `b8946` doesn't ship a `linux-arm64` artifact (check via WebFetch on https://github.com/ggerganov/llama.cpp/releases/tag/b8946 release-page asset list at task start), fetch script falls back to building from source on a `ubuntu-22.04-arm64` GitHub Actions runner (cmake -DGGML_CUDA=OFF -DGGML_VULKAN=OFF -DGGML_METAL=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF .). Cache the resulting `libllama.so` as a workflow artifact + add to checksums file.
- [ ] `.gitignore`: `runtimes/` (artifacts not source); the CI workflow re-fetches them every build. Acceptable: a fresh checkout cannot `dotnet pack` without first running `fetch-llama-binaries.sh`. Document in README.

**Acceptance**: Running `bash src/DVAIBridge.Desktop/scripts/fetch-llama-binaries.sh` populates all six RID directories with the expected library files; `verify-llama-checksums.sh` exits 0 against the checked-in checksums; `dotnet pack src/DVAIBridge.Desktop -c Release` produces a `.nupkg` ~25 MB with `runtimes/<rid>/native/` entries listed in the package contents (`unzip -l <nupkg>`).

**Effort**: 2 days (fetch script + checksum infra + RID matrix + Linux ARM64 fallback investigation).

---

## Task 16: Llama desktop native bridge — `LlamaNative.cs` + `LlamaServer.cs` + `DVAIBridge.Shared.Hosting` shared-source

**Files:**
- Create: `packages/dvai-bridge-dotnet/src/shared/DVAIBridge.Shared.Hosting/IInferenceEngine.cs` (`internal interface IInferenceEngine : IAsyncDisposable { IAsyncEnumerable<string> GenerateAsync(string prompt, GenerationOptions opts, CancellationToken ct); }`)
- Create: `packages/dvai-bridge-dotnet/src/shared/DVAIBridge.Shared.Hosting/IEmbeddingEngine.cs` (optional capability)
- Create: `packages/dvai-bridge-dotnet/src/shared/DVAIBridge.Shared.Hosting/OpenAIServer.cs` (Kestrel minimal-API host with `/v1/chat/completions`, `/v1/completions`, `/v1/embeddings`, `/v1/models`)
- Create: `packages/dvai-bridge-dotnet/src/shared/DVAIBridge.Shared.Hosting/PortPicker.cs` (binds 127.0.0.1, walks `HttpBasePort` .. `HttpBasePort + HttpMaxPortAttempts`)
- Create: `packages/dvai-bridge-dotnet/src/shared/DVAIBridge.Shared.Hosting/GenerationOptions.cs` (`record GenerationOptions(int MaxNewTokens, double Temperature, double TopP, int TopK, ...)`)
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge.Desktop/LlamaNative.cs` — `[DllImport("llama")]` declarations
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge.Desktop/LlamaInferenceEngine.cs` — `IInferenceEngine` impl
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge.Desktop/DesktopNativeBridge.cs` — `INativeBridge` impl

- [ ] `LlamaNative.cs`: minimum viable subset of llama.cpp's C API:
  - `llama_load_model_from_file`, `llama_model_free`
  - `llama_new_context_with_model`, `llama_free`
  - `llama_n_ctx`, `llama_n_vocab`
  - `llama_tokenize`, `llama_token_get_text`, `llama_token_eos`, `llama_token_bos`
  - `llama_decode`, `llama_get_logits_ith`
  - `llama_sampler_chain_init`, `llama_sampler_chain_add` (top-k, top-p, temp, dist), `llama_sampler_sample`, `llama_sampler_chain_free`
  - All declared as `[DllImport("llama", CallingConvention = CallingConvention.Cdecl)]` with sensible C# struct mappings for the opaque handle types (`LlamaModelHandle`, `LlamaContextHandle`, `LlamaSamplerChainHandle`).
- [ ] `NativeLibrary.SetDllImportResolver` in a static ctor on `LlamaNative`: looks up `runtimes/<RID>/native/llama.{dll,dylib,so}` next to the assembly first, then falls back to `NativeLibrary.Load(libraryName, assembly, searchPath)` default. Pattern matches Microsoft's `Microsoft.ML.OnnxRuntime.NativeMethods.cs` (verify exact code via WebFetch on the ORT GitHub if the resolver pattern needs cross-checking).
- [ ] `LlamaInferenceEngine.GenerateAsync`: tokenize prompt, run prefill via `llama_decode`, then loop: sample → append token → decode → yield `llama_token_get_text(token)` until EOS or `MaxNewTokens` reached. Hook `CancellationToken` between iterations (sampling is the natural break point).
- [ ] `OpenAIServer.cs`: ASP.NET Core `WebApplication.CreateBuilder(...)`, bind to `http://127.0.0.1:<port>`, register the four endpoints. Chat-completions formatter: assemble system+user+assistant turns into the model's prompt template (resolvable from `genai_config.json` for ONNX, hard-coded ChatML default for Llama with an opt-out via `StartOptions.ChatTemplate`). SSE streaming for `stream: true`.
- [ ] `DesktopNativeBridge.cs`: `INativeBridge` impl that:
  - `StartAsync` → constructs a `LlamaInferenceEngine` from `StartOptions.ModelPath`, hands it to a new `OpenAIServer`, returns the resulting `BoundServer`.
  - `StopAsync` → disposes the server + engine.
  - `GetStatusAsync` → returns `StatusInfo` from the in-memory state.
  - `DownloadModelAsync` → reuses `OpenAIServer`'s built-in HF / direct-URL downloader (pull from the cross-platform Phase 3A core if practical; otherwise reimplement minimally — checksum + atomic-rename pattern).
  - `SubscribeProgress` → wires native progress (download/load/ready phases) into a callback. Llama itself doesn't emit fine-grained load progress; we synthesize coarse `Started → Load → Ready` from `LlamaInferenceEngine.LoadAsync` lifecycle.
- [ ] Update `PlatformBridgeFactory.Create()`: when `OperatingSystem.IsWindows() || (OperatingSystem.IsLinux() && !IsAndroid()) || (OperatingSystem.IsMacOS() && !IsMacCatalyst())`, return `DesktopNativeBridge` (resolved via `Type.GetType("DVAIBridge.Desktop.DesktopNativeBridge, DVAIBridge.Desktop")`).

**Acceptance**: A standalone smoke (`dotnet run` against a tiny `TinyLlama-1.1B-Chat-v1.0-Q4_0.gguf` fixture) starts the bridge on `127.0.0.1:38883`, accepts a `POST /v1/chat/completions` with `{"model":"tinyllama","messages":[{"role":"user","content":"Hello"}]}`, and returns a non-empty completion within 10 seconds on a M-class macOS runner. Same smoke green on `windows-2022` + `ubuntu-22.04` CI runners.

**Effort**: 2.5 days (P/Invoke surface + Kestrel host + first end-to-end run).

---

## Task 17: Desktop slice xUnit tests

**Files:**
- Create: `packages/dvai-bridge-dotnet/tests/DVAIBridge.Desktop.Tests/DVAIBridge.Desktop.Tests.csproj`
- Create: `packages/dvai-bridge-dotnet/tests/DVAIBridge.Desktop.Tests/DesktopNativeBridgeTests.cs`
- Create: `packages/dvai-bridge-dotnet/tests/DVAIBridge.Desktop.Tests/PortPickerTests.cs`
- Create: `packages/dvai-bridge-dotnet/tests/DVAIBridge.Desktop.Tests/LlamaNativeSmokeTests.cs`
- Create: `packages/dvai-bridge-dotnet/tests/DVAIBridge.Desktop.Tests/Fixtures/.gitignore` (large .gguf fixture excluded)

- [ ] Tiny model fixture: TinyLlama-1.1B Q4_0 (~600 MB) — too big for git. CI fetches from a fixture mirror (HuggingFace direct URL with sha256 verification) on first test run + caches in `~/.cache/dvai-bridge-tests/`.
- [ ] `LlamaNativeSmokeTests` (Trait `"Category"="Smoke"`): exercises the `[DllImport]` surface directly — load model, create context, tokenize a 5-token prompt, decode once, free everything. **Doesn't run a full generation** (too slow + flaky for CI). Validates the P/Invoke marshalling + the `NativeLibrary.SetDllImportResolver` lookup actually resolves the right RID-keyed binary.
- [ ] `DesktopNativeBridgeTests` (Trait `"Category"="EndToEnd"`): full StartAsync → POST `/v1/chat/completions` → assert non-empty response → StopAsync. Skipped unless `DVAI_E2E=1` env var set (CI sets it on a single Linux job; PRs that need full E2E flag the workflow).
- [ ] `PortPickerTests`: walks ports under contention; verifies `HttpMaxPortAttempts` exhaustion throws the right `DVAIBridgeException(Kind: ConfigurationInvalid, Reason: "no port available in range ...")`.
- [ ] CI workflow matrix runs the Desktop tests on `windows-2022`, `ubuntu-22.04`, `macos-14` (osx-arm64 native). `windows-2022-arm64` and `ubuntu-22.04-arm64` runners are GitHub-hosted now — add them too if the runner queue isn't gated.

**Acceptance**: Smoke tests green on all 3+ runners. E2E tests green on the single linux-x64 job with `DVAI_E2E=1`. Coverage of `DesktopNativeBridge` ≥ 70% (lower than the facade target because P/Invoke calls into native code aren't trivially mockable — that's the price we pay for a real backend).

**Effort**: 1.5 days.

---

## Task 18: ONNX backend scaffold — `DVAIBridge.OnnxRuntime` csproj + `BackendKind.Onnx` wiring

**Files:**
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge.OnnxRuntime/DVAIBridge.OnnxRuntime.csproj`
- Update: `packages/dvai-bridge-dotnet/src/DVAIBridge/BackendKind.cs` — add `Onnx = 7`; update `BackendKindExtensions.ToWireString` (`"onnx"`) + `FromWireString`.
- Update: `packages/dvai-bridge-dotnet/Directory.Packages.props` — add `<PackageVersion Include="Microsoft.ML.OnnxRuntime" Version="1.25.0" />` + `<PackageVersion Include="Microsoft.ML.OnnxRuntimeGenAI" Version="0.13.1" />`.
- Update: `packages/dvai-bridge-dotnet/DVAIBridge.sln` (add the new csproj).
- Update: `packages/dvai-bridge-dotnet/src/DVAIBridge/PlatformBridgeFactory.cs` — when `BackendKind.Onnx` is requested, route to `Type.GetType("DVAIBridge.OnnxRuntime.OnnxNativeBridge, DVAIBridge.OnnxRuntime")` regardless of platform (ONNX is cross-platform).

- [ ] Confirm latest stable ORT + GenAI versions via WebFetch on https://www.nuget.org/packages/Microsoft.ML.OnnxRuntime + https://www.nuget.org/packages/Microsoft.ML.OnnxRuntimeGenAI at task start (we pinned 1.25.0 + 0.13.1 on 2026-04-27; re-verify in case a patch has shipped).
- [ ] `DVAIBridge.OnnxRuntime.csproj`:
  ```xml
  <Project Sdk="Microsoft.NET.Sdk">
    <PropertyGroup>
      <TargetFramework>net10.0</TargetFramework>
      <PackageId>DVAIBridge.OnnxRuntime</PackageId>
      <Description>ONNX Runtime backend for DVAIBridge — cross-platform LLM inference via Microsoft.ML.OnnxRuntime + OnnxRuntimeGenAI. Works on Windows / macOS / Linux desktop AND iOS / Android.</Description>
      <PackageTags>llm;ai;openai;onnx;onnxruntime;genai;phi-3;phi-4;llama;cross-platform</PackageTags>
    </PropertyGroup>
    <ItemGroup>
      <PackageReference Include="Microsoft.ML.OnnxRuntime" />
      <PackageReference Include="Microsoft.ML.OnnxRuntimeGenAI" />
      <FrameworkReference Include="Microsoft.AspNetCore.App" />
      <ProjectReference Include="../DVAIBridge/DVAIBridge.csproj" />
      <Compile Include="../shared/DVAIBridge.Shared.Hosting/*.cs" LinkBase="Shared" />
    </ItemGroup>
  </Project>
  ```
- [ ] Bump `BackendKind` enum to 9 values; add unit tests for the new `ToWireString("onnx")` round-trip (in existing `BackendKindTests.cs`).
- [ ] Update `PlatformBridgeFactory`: ONNX is cross-platform; the factory routes to `OnnxNativeBridge` when `BackendKind.Onnx` is requested AND `Type.GetType(...)` returns non-null. If the consumer asked for `BackendKind.Onnx` but didn't install `DVAIBridge.OnnxRuntime`, throw `BackendUnavailable` with the hint "install DVAIBridge.OnnxRuntime".

**Acceptance**: `dotnet build src/DVAIBridge.OnnxRuntime -c Release` exits 0. `BackendKindTests.cs` passes. Existing tests still green (no regressions on the 7 → 9 enum bump).

**Effort**: 0.5 day.

---

## Task 19: ONNX backend implementation — `OnnxNativeBridge` + `OnnxGenAIRunner`

**Files:**
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge.OnnxRuntime/OnnxNativeBridge.cs` — `INativeBridge` impl
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge.OnnxRuntime/OnnxGenAIRunner.cs` — `IInferenceEngine` impl wrapping `OnnxRuntimeGenAI.Generator`
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge.OnnxRuntime/OnnxEmbeddingRunner.cs` — `IEmbeddingEngine` impl using bare `OrtSession`

- [ ] `OnnxGenAIRunner`: wraps `OnnxRuntimeGenAI.Model.Create(modelDir)`, `OnnxRuntimeGenAI.Tokenizer`, and `OnnxRuntimeGenAI.Generator`. `GenerateAsync` constructs a `Generator` with `GeneratorParams` (max_length, temperature, top_p, top_k from `GenerationOptions`), then loops `generator.ComputeLogits()` + `generator.GenerateNextToken()` + `tokenizer.Decode(generator.GetSequence(0))` yielding incremental decoded text. Cancellation between iterations.
- [ ] `OnnxNativeBridge`: reuses `OpenAIServer` via the `IInferenceEngine` shared interface. `StartAsync` accepts `StartOptions.ModelPath` as the model directory (containing `model.onnx` + `genai_config.json` + `tokenizer.json` per HF-published convention) — validates the directory layout up-front; throws `ConfigurationInvalid` with the missing-file list if any of the three required files is absent.
- [ ] Embedding mode: when `StartOptions.EmbeddingMode == true`, skip the GenAI Generator path and use `OnnxEmbeddingRunner` (bare `OrtSession` over a sentence-transformers ONNX export). Different `IInferenceEngine` is wrong here — embeddings have a different shape; we add a parallel `IEmbeddingEngine` interface (single method `Task<float[]> EmbedAsync(string text, CancellationToken ct)`) that `OpenAIServer.cs` calls only for the `/v1/embeddings` endpoint.
- [ ] HuggingFace-style download support for `DownloadModelAsync(opts)`: accept `https://huggingface.co/microsoft/Phi-3.5-mini-instruct-onnx/resolve/main/...` URLs + sha256-verify each file (HF tracks per-file hashes in `model_index.json` / LFS metadata; we walk the directory listing).

**Acceptance**: A standalone smoke (`dotnet run` against a `microsoft/Phi-3-mini-4k-instruct-onnx` model directory — ~2 GB; CI uses a smaller fixture from `onnx-community/Llama-3.2-1B-Instruct-q4f16-onnx` ~700 MB) starts the bridge, accepts `POST /v1/chat/completions` with streaming, returns non-empty tokens. Same smoke green on Windows / Linux / macOS desktop runners. Mobile smoke deferred to Task 20 (mobile CI runners are slower and we test the basic Generator API on desktop first).

**Effort**: 1.5 days.

---

## Task 20: ONNX xUnit tests

**Files:**
- Create: `packages/dvai-bridge-dotnet/tests/DVAIBridge.OnnxRuntime.Tests/DVAIBridge.OnnxRuntime.Tests.csproj`
- Create: `packages/dvai-bridge-dotnet/tests/DVAIBridge.OnnxRuntime.Tests/OnnxNativeBridgeTests.cs`
- Create: `packages/dvai-bridge-dotnet/tests/DVAIBridge.OnnxRuntime.Tests/OnnxGenAIRunnerTests.cs`
- Create: `packages/dvai-bridge-dotnet/tests/DVAIBridge.OnnxRuntime.Tests/OnnxEmbeddingRunnerTests.cs`

- [ ] Trait `"Category"="Smoke"` tests: load tiny ONNX classifier (~2 MB; we use a hand-built MNIST-style test fixture that can ship in git) — verifies `OrtSession` round-trip works on every CI runner without large-model-fetch flakiness.
- [ ] Trait `"Category"="EndToEnd"` tests: load `onnx-community/Llama-3.2-1B-Instruct-q4f16-onnx` (~700 MB; fetched + cached like Task 17), full StartAsync + POST `/v1/chat/completions` + StopAsync. Skipped unless `DVAI_E2E=1`.
- [ ] Cancellation: mid-generation `cts.Cancel()` exits the `Generator` loop within 100ms.
- [ ] Embedding round-trip: load a sentence-transformers ONNX export (we use `Xenova/all-MiniLM-L6-v2` ~25 MB; small enough to ship as a CI fixture), POST `/v1/embeddings` with two strings, verify the returned vectors are length-384 and dot-product agrees with a CPU-Python reference within 1e-4.
- [ ] `BackendKind.Onnx` round-trips wire-string in `BackendKindTests.cs` (already covered in Task 18 but re-verify).

**Acceptance**: Smoke green on all 3 desktop runners. E2E green on linux-x64 with `DVAI_E2E=1`. Coverage of `OnnxNativeBridge` + `OnnxGenAIRunner` ≥ 70%.

**Effort**: 1 day.

---

## Task 21: ML.NET backend scaffold + implementation — `DVAIBridge.MLNet` + `MLNetNativeBridge`

**Files:**
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge.MLNet/DVAIBridge.MLNet.csproj`
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge.MLNet/MLNetNativeBridge.cs` — `INativeBridge` impl
- Create: `packages/dvai-bridge-dotnet/src/DVAIBridge.MLNet/MLNetInferenceEngine.cs` — `IInferenceEngine` impl wrapping `MLContext` + `OnnxScoringEstimator`
- Update: `packages/dvai-bridge-dotnet/src/DVAIBridge/BackendKind.cs` — add `MLNet = 8`; update wire-string round-trip (`"mlnet"`).
- Update: `packages/dvai-bridge-dotnet/Directory.Packages.props` — add `<PackageVersion Include="Microsoft.ML" Version="5.0.0" />` + `<PackageVersion Include="Microsoft.ML.OnnxTransformer" Version="5.0.0" />`.
- Update: `packages/dvai-bridge-dotnet/DVAIBridge.sln` (add the new csproj).
- Update: `packages/dvai-bridge-dotnet/src/DVAIBridge/PlatformBridgeFactory.cs` — route `BackendKind.MLNet` to `MLNetNativeBridge` IF (`OperatingSystem.IsWindows()` OR `IsLinux()` OR `(IsMacOS() && !IsMacCatalyst())`); reject with `BackendUnavailable("MLNet desktop only — use BackendKind.Onnx on mobile")` otherwise.

- [ ] Confirm latest stable ML.NET version via WebFetch on https://www.nuget.org/packages/Microsoft.ML at task start (we pinned 5.0.0 on 2026-04-27 — released alongside .NET 10 GA on 2025-11-11; re-verify).
- [ ] `MLNetInferenceEngine`: builds an `MLContext` + `OnnxScoringEstimator` pipeline with `inputColumnNames = ["input_ids"]`, `outputColumnNames = ["logits"]`. `Fit` runs once on an empty `IDataView` (the estimator becomes a transformer). `GenerateAsync` loops: tokenize → wrap in `IDataView` → `transformer.Transform(...)` → extract logits → manual sampler → next token. Less elegant than OnnxRuntimeGenAI's Generator API, but matches ML.NET's pipeline shape.
- [ ] Hand-rolled tokenizer + sampler: ML.NET doesn't ship LLM-specific helpers. We pull `Microsoft.ML.Tokenizers` (now stable, ships with .NET 10) for HF-tokenizer-json compatibility, and implement top-k / top-p / temperature sampling manually (~80 LOC, well-trodden code).
- [ ] `MLNetNativeBridge`: same shape as `DesktopNativeBridge` / `OnnxNativeBridge` — reuses `OpenAIServer`. Document that the recommended use case is "you already have an ML.NET pipeline and want to add an LLM transform"; for greenfield consumers, point at `BackendKind.Onnx`.

**Acceptance**: `dotnet build src/DVAIBridge.MLNet -c Release` exits 0. A standalone smoke against the same `onnx-community/Llama-3.2-1B-Instruct-q4f16-onnx` fixture starts the bridge, accepts `POST /v1/chat/completions`, returns non-empty tokens (slower than the direct ONNX path; document the perf delta in the consumer guide).

**Effort**: 1.5 days.

---

## Task 22: ML.NET xUnit tests

**Files:**
- Create: `packages/dvai-bridge-dotnet/tests/DVAIBridge.MLNet.Tests/DVAIBridge.MLNet.Tests.csproj`
- Create: `packages/dvai-bridge-dotnet/tests/DVAIBridge.MLNet.Tests/MLNetNativeBridgeTests.cs`

- [ ] Smoke: load the same hand-built MNIST-style ONNX from Task 20, run a single `transformer.Transform`, verify shape. Validates the ML.NET pipeline integration without large-model fetch.
- [ ] EndToEnd (Trait, gated by `DVAI_E2E=1`): same Llama-3.2-1B fixture, full chat-completions round-trip; expected slower than the `Onnx` E2E (we assert it returns within 60s rather than 30s on linux-x64).
- [ ] Mobile rejection: instantiate `MLNetNativeBridge` on a synthetic-iOS-platform test runner (via the `IOperatingSystemAdapter` indirection from rev 1 Task 9), verify `StartAsync` throws `BackendUnavailable` with the "use BackendKind.Onnx on mobile" hint.

**Acceptance**: Smoke green on all 3 desktop runners. E2E green on linux-x64 with `DVAI_E2E=1`. Coverage of `MLNetNativeBridge` + `MLNetInferenceEngine` ≥ 70%.

**Effort**: 0.5 day.

---

## Task 23: Fix `ProgressBroadcaster` cancellation race

**Background**: surfaced during v2.4.0-rc1 build verification. `ProgressBroadcaster.Subscribe(ct)` removes its channel from `_subscribers` in the `finally` block of the `await foreach` — but `Emit(...)` reads the dictionary keys without taking the same lock the `TryRemove` uses internally. Under contention, `Emit` can `TryWrite` to a channel that's just been completed by the cancellation path. Always a no-op (the channel writer is closed), but the static analyzer flags it and consumers report sporadic `ObjectDisposedException`s in logs (the `Channel<T>` source raises one on completed-channel writes in some pre-release builds of .NET 10 service updates).

**Files:**
- Update: `packages/dvai-bridge-dotnet/src/DVAIBridge/ProgressBroadcaster.cs`
- Update: `packages/dvai-bridge-dotnet/tests/DVAIBridge.Tests/ProgressBroadcasterTests.cs`

- [ ] Replace the `_subscribers.Keys` iteration in `Emit` with a snapshot copy taken under `_subscribers`'s internal lock (`var snapshot = _subscribers.Keys.ToArray();` is enough — the `ConcurrentDictionary.Keys` accessor materializes the snapshot atomically). Then iterate the snapshot.
- [ ] In the `finally` of `Subscribe`, wrap `ch.Writer.TryComplete()` in a `try { ... } catch (ChannelClosedException) { /* expected if Dispose ran in parallel */ }` and add a state-check (`if (!_disposed)`).
- [ ] Add a stress test: 8 producer threads calling `Emit` in a tight loop, 8 consumer tasks each `await foreach`ing with random-cancellation-after-N-events. Run for 5 seconds. Assert no `ObjectDisposedException` / `InvalidOperationException` escapes either side.
- [ ] Add a regression test for the original reported symptom: `Subscribe → Cancel within 1ms → Subscribe again → Emit` does not throw (verifying the race window).

**Acceptance**: `ProgressBroadcasterTests` green including the new stress + regression tests under repeated runs (`for i in {1..50}; do dotnet test --filter Category=Stress; done` exits 0 every iteration).

**Effort**: 0.5 day.

---

## Task 24: Update `BackendKind` (7 → 9) + `PlatformBridgeFactory` routing for all 5 native bridges

**Files:**
- Update: `packages/dvai-bridge-dotnet/src/DVAIBridge/BackendKind.cs` — final 9-case enum (covered piecewise by Tasks 18 + 21; this task is the consolidating audit).
- Update: `packages/dvai-bridge-dotnet/src/DVAIBridge/PlatformBridgeFactory.cs` — full routing logic per the §3.8 matrix.
- Update: `packages/dvai-bridge-dotnet/tests/DVAIBridge.Tests/BackendKindTests.cs` — full 9-case round-trip test.
- Update: `packages/dvai-bridge-dotnet/tests/DVAIBridge.Tests/PlatformBridgeFactoryTests.cs` (new file) — exhaustive (BackendKind × Platform) matrix test using the synthetic-OS adapter.

- [ ] Routing logic in `Create()`:
  ```
  if (BackendKind in {Onnx} && DVAIBridge.OnnxRuntime loaded)        → OnnxNativeBridge
  else if (BackendKind in {MLNet} && desktop && DVAIBridge.MLNet loaded) → MLNetNativeBridge
  else if (iOS || Catalyst) && BackendKind in {Auto, Llama, Foundation, CoreML, MLX}  → IOSNativeBridge
  else if (Android) && BackendKind in {Auto, Llama, MediaPipe, LiteRT}  → AndroidNativeBridge
  else if (desktop) && BackendKind in {Auto, Llama}                  → DesktopNativeBridge
  else throw BackendUnavailable("...")
  ```
- [ ] Hint messages on `BackendUnavailable` are explicit: "BackendKind.Onnx requires the DVAIBridge.OnnxRuntime NuGet — install it via `dotnet add package DVAIBridge.OnnxRuntime`."
- [ ] `PlatformBridgeFactoryTests`: 9 BackendKind values × 5 platforms (iOS / Catalyst / Android / Windows / Linux / macOS-desktop) = 54 cells. Each cell asserts the right outcome (specific bridge type, or specific `BackendUnavailable` hint). Use `[Theory]` + `[MemberData]` to enumerate.
- [ ] Verify the 5 facade tests that failed in v2.4.0-rc1 (the `UnsupportedPlatformBridge` fall-through ones) now pass on Windows / Linux / macOS-desktop CI runners — the `DesktopNativeBridge` is what they expected.

**Acceptance**: `BackendKind` enum has exactly 9 values; wire-string round-trips work for all of them; the matrix test passes; the 5 previously-failing facade tests pass on desktop CI.

**Effort**: 0.5 day.

---

## Task 25: Documentation — guide + per-backend sections + migration v2.3→v2.4 + CI workflow

**Files:**
- Update: `docs/guide/dotnet-sdk.md` — major expansion
- Update: `docs/migration/v2.3-to-v2.4.md` — major expansion
- Update: `.github/workflows/test-dotnet.yml` — add desktop / ONNX / MLNet matrix dimensions
- Update: `docs/.vitepress/config.ts` — sidebar entries (no new pages, just reordering — the .NET SDK page was added in rev 1 Task 10)

- [ ] `docs/guide/dotnet-sdk.md` revision:
  - **Decision matrix at the top** ("I'm building a Windows desktop app → use `DVAIBridge.Desktop` with `BackendKind.Llama` OR `DVAIBridge.OnnxRuntime` with `BackendKind.Onnx`").
  - **Install snippets for all 6 packages** with copy-paste-ready `dotnet add package` lines.
  - **Backend selection guide** — when to choose which backend on which platform (uses the §3.8 matrix from the spec).
  - **Per-backend sections**:
    - `BackendKind.Llama` — works everywhere; needs `DVAIBridge.Desktop` for desktop, the existing iOS/Android slices for mobile.
    - `BackendKind.Foundation` / `CoreML` / `MLX` — iOS + Catalyst only; same content as v2.4.0-rc1 docs.
    - `BackendKind.MediaPipe` / `LiteRT` — Android only; same content as v2.4.0-rc1 docs.
    - `BackendKind.Onnx` — cross-platform; model catalog (Phi-3.5, Phi-4, Llama-3.2 ONNX); `genai_config.json` directory layout; HF download examples.
    - `BackendKind.MLNet` — desktop primary; "use this if you're already in ML.NET" framing; honest perf-vs-Onnx note (~1.4× slower in our benchmarks).
  - **ONNX vs ML.NET trade-off table** (lifted verbatim from spec §3.7.3).
  - **Why doesn't iOS / Android / RN / Flutter expose Onnx / MLNet?** subsection — explain the .NET-specificity (rev 2 Q11 rationale).
  - **Mac Catalyst** — "use the same `DVAIBridge.iOS` NuGet; it multi-targets `net10.0-maccatalyst18.0`".
  - **Updated quickstart** — show a Windows MAUI desktop example with `BackendKind.Llama` + `DVAIBridge.Desktop`, then a `BackendKind.Onnx` example with a Phi-3.5 model.
- [ ] `docs/migration/v2.3-to-v2.4.md` revision:
  - Original v2.3-to-v2.4 content (mobile-only, NuGet.org distribution, .NET 10 prereq) stays.
  - Add: "v2.4.0-rc1 → v2.4.0 — desktop + ONNX + ML.NET" sub-section explaining the new packages for consumers who tracked the rc.
  - Add: "Why .NET has 9 BackendKind cases when other wrappers have 7" subsection.
  - Add: install matrix — what to install for each consumer scenario (mobile-only / desktop-only / cross-platform / desktop+ONNX / desktop+MLNet).
- [ ] `.github/workflows/test-dotnet.yml` revision:
  - Add desktop matrix: `os: [windows-2022, ubuntu-22.04, macos-14]` (osx-arm64 native), with `windows-2022-arm64` + `ubuntu-22.04-arm64` if available.
  - Add `bash src/DVAIBridge.Desktop/scripts/fetch-llama-binaries.sh` step before the desktop builds.
  - Add `bash src/DVAIBridge.Desktop/scripts/verify-llama-checksums.sh` step (fail fast on supply-chain drift).
  - Run desktop / ONNX / MLNet test projects on each desktop runner.
  - Tag-push job extends to `dotnet pack` + `dotnet nuget push` for all **6** NuGet packages.
- [ ] Decision matrix at top of `dotnet-sdk.md` to be a literal quick-reference table:
  | I'm building...                           | Install                                        | Use BackendKind...           |
  |-------------------------------------------|------------------------------------------------|------------------------------|
  | iOS-only MAUI                             | `DVAIBridge` (auto-pulls `.iOS`)               | `Auto` / `Llama` / `CoreML`  |
  | Android-only MAUI                         | `DVAIBridge` (auto-pulls `.Android`)           | `Auto` / `Llama` / `MediaPipe` |
  | iOS + macOS Catalyst MAUI                 | `DVAIBridge` (auto-pulls `.iOS` for both)      | `Auto` / `Llama` / `CoreML`  |
  | Windows desktop / Avalonia / WinUI        | `DVAIBridge` (auto-pulls `.Desktop`)           | `Auto` / `Llama`             |
  | Cross-platform server / console           | `DVAIBridge` + `DVAIBridge.OnnxRuntime`        | `Onnx`                       |
  | Existing ML.NET pipeline + LLM transform  | `DVAIBridge` + `DVAIBridge.MLNet`              | `MLNet`                      |

**Acceptance**: `pnpm run docs:build` exits 0; the .NET SDK page renders the decision matrix correctly; the migration guide is comprehensive enough that an existing v2.4.0-rc1 user can upgrade without questions; the CI workflow runs green on every matrix dimension on a test PR.

**Effort**: 1 day.

---

## Task 26: Version bump 2.3.0 → 2.4.0 + CHANGELOG + tag + 6-NuGet publish (replaces rev 1 Task 14)

**Files:**
- Update: `package.json` (root) — bump 2.3.0 → 2.4.0
- Update: `packages/dvai-bridge-dotnet/package.json` — bump 2.3.0 → 2.4.0
- Update: `packages/dvai-bridge-dotnet/Directory.Build.props` — bump 2.3.0 → 2.4.0
- Update: `packages/dvai-bridge-android/android/gradle.properties` — already 2.4.0 from rev 1 Task 7
- Update: `packages/dvai-bridge-dotnet/CHANGELOG.md` — release entry
- Update: `CHANGELOG.md` (root) — `## [2.4.0] — YYYY-MM-DD` covering the full .NET family + Desktop + ONNX + MLNet + Android AAR republish
- Update: `PUBLISHING.md` (gitignored) — `dotnet nuget push` steps for all 6 NuGets

- [ ] Run `node scripts/sync-versions.js` + `node scripts/sync-package-meta.js`. Confirm `Directory.Build.props`'s `<Version>` propagates to all 6 csprojs (CPM-driven; one source of truth).
- [ ] CHANGELOG entry under `## [2.4.0] — YYYY-MM-DD`:
  - Added: .NET NuGet package family — **6 packages** (`DVAIBridge`, `DVAIBridge.iOS` w/ Catalyst, `DVAIBridge.Android`, `DVAIBridge.Desktop`, `DVAIBridge.OnnxRuntime`, `DVAIBridge.MLNet`) on NuGet.org.
  - .NET 10 LTS facade with TFM-conditional + RID-keyed platform slices, idiomatic `IAsyncEnumerable<ProgressEvent>` reactive surface (`ProgressBroadcaster` fan-out), 9-case `BackendKind` (`Auto` / `Llama` / `Foundation` / `CoreML` / `MLX` / `MediaPipe` / `LiteRT` / `Onnx` / `MLNet`).
  - Desktop slice: `llama.cpp` `b8946` prebuilts per RID (win-x64 / win-arm64 / osx-x64 / osx-arm64 / linux-x64 / linux-arm64) + Kestrel-hosted OpenAI-compatible HTTP API.
  - ONNX backend: `Microsoft.ML.OnnxRuntime` 1.25.0 + `Microsoft.ML.OnnxRuntimeGenAI` 0.13.1 — cross-platform LLM via Phi-3.5 / Phi-4 / Llama-3.2 ONNX.
  - ML.NET backend: `Microsoft.ML` 5.0.0 + `Microsoft.ML.OnnxTransformer` 5.0.0 — desktop-primary; integrates with existing ML.NET pipelines.
  - Mac Catalyst: free reuse via multi-target TFM in `DVAIBridge.iOS.csproj`.
  - Fixed: `ProgressBroadcaster` cancellation race (Task 23).
  - Changed: Phase 3D Android AAR republished at 2.4.0 for build-graph alignment (no source changes).
  - Notes: all 6 .NET packages published to NuGet.org (vs Maven/npm GitHub-Packages part of the family); see `docs/migration/v2.3-to-v2.4.md`. ONNX / MLNet are .NET-specific — iOS / Android / RN / Flutter wrappers do not expose them.
- [ ] PUBLISHING.md flow:
  1. `git tag v2.4.0` + push
  2. CI publishes the Android AAR to GitHub Packages
  3. CI builds the iOS+Catalyst xcframework on macos-latest, fetches llama.cpp `b8946` prebuilts on each desktop runner, packs all 6 NuGets on macos-latest (the iOS slice needs a Mac runner; the others are platform-agnostic but we colocate to keep the publish step single-runner).
  4. CI runs `dotnet nuget push ./out/*.nupkg --source https://api.nuget.org/v3/index.json --api-key ${{ secrets.NUGET_API_KEY }} --skip-duplicate` for each of the 6 nupkg files (loop in the workflow).
  5. Verify NuGet.org pages at https://www.nuget.org/packages/DVAIBridge / .iOS / .Android / .Desktop / .OnnxRuntime / .MLNet show 2.4.0 within ~10 minutes (NuGet.org indexing latency).
  6. Smoke test: in a fresh `dotnet new console -f net10.0` project on Windows, `dotnet add package DVAIBridge --version 2.4.0` and `dotnet run` the §3.2 quickstart snippet — verifies the full restore + Desktop slice + Llama runtime path works on a clean machine.
- [ ] Commit + tag `v2.4.0` + push.

**Acceptance:**
- `pnpm install` succeeds at 2.4.0.
- `bash scripts/verify-cap-sync.sh` exits 0 (existing script must tolerate the 3 new csprojs; confirm or extend).
- `git tag --list | grep v2.4.0` shows the new tag.
- `dotnet pack` from the solution root produces **six** `.nupkg` + six `.snupkg` files at version 2.4.0.
- All 6 NuGets visible on NuGet.org at v2.4.0.
- The clean-machine smoke (step 6 above) returns a non-empty completion from a Phi-3-mini or TinyLlama model within 30 seconds.

**Effort**: 0.5 day.

---

## Test strategy summary (rev 2)

| Layer                                           | Tool                                       | Where                                                                       |
|-------------------------------------------------|--------------------------------------------|-----------------------------------------------------------------------------|
| C# unit tests (facade)                          | `dotnet test` + xUnit + Moq + Coverlet     | `packages/dvai-bridge-dotnet/tests/DVAIBridge.Tests/`                       |
| C# unit tests (desktop)                         | `dotnet test` + xUnit                      | `tests/DVAIBridge.Desktop.Tests/`                                           |
| C# unit tests (ONNX)                            | `dotnet test` + xUnit                      | `tests/DVAIBridge.OnnxRuntime.Tests/`                                       |
| C# unit tests (ML.NET)                          | `dotnet test` + xUnit                      | `tests/DVAIBridge.MLNet.Tests/`                                             |
| Static analysis                                 | `dotnet build` with `<TreatWarningsAsErrors>` + nullable | per-csproj; CI workflow                                       |
| iOS + Catalyst binding sanity                   | `dotnet build src/DVAIBridge.iOS -f $TFM` per multi-target | CI macos runner                                            |
| Android binding sanity                          | `dotnet build src/DVAIBridge.Android`      | CI ubuntu runner                                                            |
| Desktop P/Invoke smoke                          | `LlamaNativeSmokeTests`                    | windows-2022 + ubuntu-22.04 + macos-14 CI runners                           |
| Desktop end-to-end (TinyLlama 1.1B)             | `DesktopNativeBridgeTests` (gated by `DVAI_E2E=1`) | linux-x64 CI job                                                    |
| ONNX end-to-end (Phi-3-mini / Llama-3.2-1B)     | `OnnxNativeBridgeTests` (gated by `DVAI_E2E=1`)    | linux-x64 CI job                                                    |
| ML.NET end-to-end                               | `MLNetNativeBridgeTests` (gated by `DVAI_E2E=1`)   | linux-x64 CI job                                                    |
| iOS xcframework build (3 slices)                | `bash build-xcframework.sh`                | CI macos runner                                                             |
| llama.cpp prebuild fetch + checksum verify      | `fetch-llama-binaries.sh` + `verify-llama-checksums.sh` | each desktop CI runner before pack                            |
| Pack dry-run                                    | `dotnet pack -c Release -o ./out`          | CI macos runner (final pack of all 6 NuGets)                                |
| End-to-end runtime (.NET MAUI / Avalonia consumer) | scripted snippets in `docs/guide/dotnet-sdk.md` | docs only — scripted per project convention                            |
| NuGet.org publish dry-run                       | `dotnet nuget push --no-symbols` (no key)  | CI tag-push — auth-fail is the success signal                               |
| Clean-machine consumer smoke (Task 26)          | `dotnet new console + dotnet add package DVAIBridge` | manual on a Windows VM post-publish                              |
| Coverage reporting                              | Coverlet → XPlat Code Coverage             | CI artifact upload                                                          |

## Risk register

1. **Microsoft's `IsBindingProject=true` semantics shift between .NET versions.** .NET 8 → .NET 9 → .NET 10 each tweaked the Java/Obj-C binding pipelines. Pin exact .NET 10 SDK version in `global.json`. If a service release breaks bindings, freeze the CI image at the working SDK and document.
2. **MLX backend under CocoaPods**: known limitation from Phase 3C. Doesn't apply directly to .NET (we ship the xcframework via NuGet, not via CocoaPods). But if a consumer overrides via `<NativeReference>` to point at a CocoaPods-built `DVAIBridge.framework`, MLX would still be unavailable. Document; default consumer experience is fine.
3. **Android consumer's GitHub Packages Maven repo setup is non-trivial** — consumers need a personal access token. Document the consumer-side `<AndroidMavenLibrary>` + nuget.config snippet thoroughly (mirror the language used in `docs/guide/android-native-sdk.md`). This is the same friction Flutter consumers see in 3F.
4. **NuGet.org publish requires a verified Microsoft account + NuGet.org publisher.** Add this prerequisite to PUBLISHING.md. The first publish must come from a maintainer's NuGet.org-linked Microsoft account; subsequent publishes use API keys via CI secrets (`NUGET_API_KEY`). Set up in Phase 3H if not already.
5. **`Channel<T>` broadcast semantics**: as of .NET 10, `Channel.CreateUnbounded` doesn't fan out to multiple readers — each reader competes for items. Test (Task 9) the multi-consumer case; if broadcast is needed, switch to a custom multicast wrapper. For v2.4 we accept "first reader wins" as documented behavior — most consumers want one `await foreach` loop anyway. Phase 4 candidate: explicit `IObservable<T>`-style broadcast.
6. **NativeAOT flagging on iOS**: ATM bindings produce trim warnings but don't block build. .NET 10's stricter trim analyzer may upgrade these to errors in a service release. Pin SDK version in `global.json`; if errors appear, suppress with `<TrimmerRootDescriptor>` files until Phase 4 fixes them properly.
7. **Swift wrapper xcframework size**: the static-link strategy produces a ~3 MB binary. If a Phase 3C update adds new transitive deps (e.g. MLX), the xcframework could balloon. Set a 10 MB ceiling; alert in CI if exceeded.
8. **Cross-platform `DVAIBridge` class name collision**: the public C# class `DVAIBridge` in the facade and the bound Java type `Co.Deepvoiceai.Bridge.NativeDVAIBridge` (renamed via Metadata.xml) and the bound Obj-C type `DVAIBridge.iOS.Native.DVAIBridgeNetBridge` are all distinct types in distinct namespaces. C# resolves them unambiguously by namespace. Document for IDE-discoverability concerns.
9. **`OperatingSystem.IsIOS()` testability**: the static method isn't directly mockable. Task 9 introduces a thin `IOperatingSystemAdapter` indirection or a `[ThreadStatic]` test-override field. Pick the cleaner of the two during implementation.
10. **First-time NuGet authoring**: this is the family's first NuGet publish. PUBLISHING.md must include the NuGet.org account-setup walkthrough. Allow a 1-day buffer in the launch schedule for unexpected NuGet.org friction.

### Rev 2 risks (added)

11. **llama.cpp `b8946` Linux ARM64 prebuilt may be missing**: upstream's CI matrix is x64-heavy historically. Task 15 includes a from-source fallback build on `ubuntu-22.04-arm64` runners. If the runner queue for ARM64 is gated (it was originally beta-only), we may have to build the linux-arm64 binary on a self-hosted runner or skip the RID for v2.4.0 (drops linux-arm64 support; documents in known-issues). Mitigation: confirm runner availability at Task 15 start; have the from-source fallback ready.
12. **`Microsoft.ML.OnnxRuntimeGenAI` API churn**: GenAI is at v0.13.1 (pre-1.0); the `Generator` API has changed shape between minor versions historically. Pin exact `0.13.1` in CPM; on minor bump (0.14, 0.15), re-run the test suite + adjust the `OnnxGenAIRunner` wrapper. Document in the consumer guide that we track ORT GenAI minor releases and may bump the `DVAIBridge.OnnxRuntime` major version when they break compat.
13. **ML.NET LLM perf is meaningfully worse than direct ORT**: the ML.NET pipeline overhead per token (~1.4× in our benchmark estimates) is acceptable for "you're already in ML.NET" use cases but a footgun if a consumer reaches for `MLNet` thinking it's the canonical .NET LLM choice. Mitigation: docs steer toward `Onnx` aggressively; the `BackendKind` order (`Onnx = 7` before `MLNet = 8`) follows the recommendation order; Visual Studio IntelliSense renders enum members in declaration order so consumers see `Onnx` first.
14. **Kestrel inside library hosting**: ASP.NET Core's Kestrel host expects to be the process's main host. Embedding it inside a non-web process (a console app, a MAUI desktop app) works but has documented pitfalls — graceful shutdown signals don't always reach Kestrel cleanly when the parent app exits abruptly. Mitigation: register `Application.Current.Exiting` / `AppDomain.CurrentDomain.ProcessExit` hooks that call `OpenAIServer.StopAsync(timeout: 5s)` defensively; document in the consumer guide.
15. **Desktop NuGet size**: ~25 MB uncompressed across 6 RIDs of llama.cpp natives. NuGet.org's per-package size limit is 250 MB so we're well under, but the `.nupkg` itself is ~6 MB compressed (acceptable). If we ever add CUDA / Vulkan / Metal builds (Phase 4+), the per-RID native size grows 3–5×; revisit then.
16. **`NativeLibrary.SetDllImportResolver` and AOT**: the resolver pattern is AOT-friendly *if* registered before any `[DllImport]` is hit (i.e. in a static ctor or `ModuleInitializer`). We use `ModuleInitializer` to be safe. Phase 4 NativeAOT story adds it back as a candidate for re-enablement.
17. **Catalyst symbol resolution at runtime**: in `IOSNativeBridge.cs`, the bound class refers to `DVAIBridgeNetBridge` — which on Catalyst lives at the Catalyst slice of the xcframework. If `xcodebuild -create-xcframework` mis-orders the slices, the runtime loader can pick the wrong `Info.plist` and fail. Mitigation: Task 14 acceptance includes inspecting the xcframework's `AvailableLibraries` keys to confirm three slices are listed correctly.

## Out-of-scope (rev 2)

- ~~WinUI 3 / Avalonia / desktop native backends (Phase 4+).~~ → Now in-scope (Tasks 15–17).
- ~~Mac Catalyst / tvOS / watchOS targets (Phase 4+).~~ → Catalyst now in-scope (Task 14); tvOS / watchOS remain out-of-scope.
- tvOS, watchOS, browser-wasm targets (Phase 4+ if real-world demand materializes; no LLM use case for tvOS/watchOS yet, and wasm is incompatible with both `llama.cpp` and ORT's WebAssembly story).
- Xamarin.Forms / classic Xamarin.iOS / classic Xamarin.Android targets (EOL since 2024).
- F# / VB.NET-specific API surface (works via standard CLR interop).
- NativeAOT-clean binding slices (Phase 4 candidate). The desktop slice's `[DllImport]` + `NativeLibrary.SetDllImportResolver` IS AOT-friendly; the binding slices (iOS / Android) are not.
- GPU acceleration on desktop (CUDA / Vulkan / ROCm / Metal): Phase 4+. v2.4 ships CPU-only `llama.cpp` builds.
- Cross-family `Onnx` / `MLNet` `BackendKind` cases on iOS / Android / RN / Flutter (decided rev 2 Q11 — .NET-specific; revisit in Phase 4+ if demand materializes).
- iOS-side / Android-side `BackendKind.MLNet` (rejected at facade — use `BackendKind.Onnx` on mobile).
- Source generators / Roslyn analyzers for backend-platform-mismatch (runtime check is sufficient for v2.4).
- `IObservable<T>` first-class API (Rx interop one-liner is sufficient).
- GitHub Packages NuGet feed (NuGet.org chosen; see spec §4.1).
- Sample app source — scripted only (per project convention).
- iOS / Android source changes beyond the AAR republish at 2.4.0 (rev 1 Task 7).
- Self-hosted llama.cpp build farm — we use upstream's prebuilt release artifacts (rev 2 Task 15).
- launch (3H).

## References

- Spec: [docs/superpowers/specs/2026-04-27-phase3g-dotnet-package-design.md](../specs/2026-04-27-phase3g-dotnet-package-design.md)
- iOS counterpart spec: [docs/superpowers/specs/2026-04-26-phase3c-ios-native-sdk-design.md](../specs/2026-04-26-phase3c-ios-native-sdk-design.md)
- Android counterpart spec: [docs/superpowers/specs/2026-04-27-phase3d-android-native-sdk-design.md](../specs/2026-04-27-phase3d-android-native-sdk-design.md)
- React Native counterpart plan: [docs/superpowers/plans/2026-04-27-phase3e-react-native-module.md](2026-04-27-phase3e-react-native-module.md)
- Flutter counterpart plan: [docs/superpowers/plans/2026-04-27-phase3f-flutter-package.md](2026-04-27-phase3f-flutter-package.md)
- .NET 10 release announcement: https://devblogs.microsoft.com/dotnet/announcing-dotnet-10/
- .NET support policy (.NET 10 LTS through 2028-11-14): https://dotnet.microsoft.com/en-us/platform/support/policy/dotnet-core
- Target frameworks (`net10.0-ios`, `net10.0-android`): https://learn.microsoft.com/en-us/dotnet/standard/frameworks
- .NET MAUI 10 supported platforms: https://learn.microsoft.com/en-us/dotnet/maui/supported-platforms?view=net-maui-10.0
- Native Library Interop (Swift @objc wrapper pattern): https://devblogs.microsoft.com/dotnet/native-library-interop-dotnet-maui/
- Native Library Interop docs: https://learn.microsoft.com/en-us/dotnet/communitytoolkit/maui/native-library-interop/get-started
- iOS bindings migration: https://learn.microsoft.com/en-us/dotnet/maui/migration/ios-binding-projects
- Android bindings migration: https://learn.microsoft.com/en-us/dotnet/maui/migration/android-binding-projects
- IAsyncEnumerable vs IObservable: https://dev.to/asik/comparing-iasyncenumerable-and-iobservable-for-event-streams-5g96
- System.Threading.Channels guide: https://learn.microsoft.com/en-us/dotnet/core/extensions/channels
- NuGet Central Package Management: https://learn.microsoft.com/en-us/nuget/consume-packages/central-package-management
- NativeAOT for iOS state: https://github.com/dotnet/macios/blob/main/docs/nativeaot.md
- GitHub Packages NuGet (rejected for 3G; documented for completeness): https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-nuget-registry

### Rev 2 references

- llama.cpp release `b8946`: https://github.com/ggerganov/llama.cpp/releases/tag/b8946
- llama.cpp public C API: https://github.com/ggerganov/llama.cpp/blob/master/include/llama.h
- `Microsoft.ML.OnnxRuntime` 1.25.0 NuGet: https://www.nuget.org/packages/Microsoft.ML.OnnxRuntime
- `Microsoft.ML.OnnxRuntimeGenAI` 0.13.1 NuGet: https://www.nuget.org/packages/Microsoft.ML.OnnxRuntimeGenAI
- ONNX Runtime GenAI Generator API: https://onnxruntime.ai/docs/genai/api/csharp.html
- HuggingFace ONNX-GenAI model directory layout: https://huggingface.co/microsoft/Phi-3.5-mini-instruct-onnx
- `Microsoft.ML` 5.0.0 NuGet: https://www.nuget.org/packages/Microsoft.ML
- `Microsoft.ML.OnnxTransformer` 5.0.0 NuGet: https://www.nuget.org/packages/Microsoft.ML.OnnxTransformer
- ML.NET Documentation: https://learn.microsoft.com/en-us/dotnet/machine-learning/
- `Microsoft.ML.Tokenizers` (HF-compat tokenizer for the MLNet path): https://www.nuget.org/packages/Microsoft.ML.Tokenizers
- .NET Runtime Identifier (RID) catalog: https://learn.microsoft.com/en-us/dotnet/core/rid-catalog
- `<RuntimeIdentifiers>` + `runtimes/<rid>/native/` packing convention: https://learn.microsoft.com/en-us/nuget/create-packages/native-files-in-net-packages
- `NativeLibrary.SetDllImportResolver` (explicit native lookup): https://learn.microsoft.com/en-us/dotnet/standard/native-interop/native-library-loading
- Mac Catalyst TFM in .NET 10: https://learn.microsoft.com/en-us/dotnet/standard/frameworks#net-tfms-with-os-versions
- Kestrel inside library hosting (best practices for embedded HTTP servers): https://learn.microsoft.com/en-us/aspnet/core/fundamentals/servers/kestrel/
- `ModuleInitializer` for early P/Invoke setup: https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/proposals/csharp-9.0/module-initializers
