# Phase 3G — .NET NuGet Packages Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to execute this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Branch:** `feat/phase3g-dotnet-nuget`

**Goal:** Stand up `packages/dvai-bridge-dotnet/` — three NuGet packages (`DVAIBridge` facade, `DVAIBridge.iOS` bindings, `DVAIBridge.Android` bindings) on NuGet.org. Wraps the v2.3 iOS DVAIBridge SDK + v2.4 Android DVAIBridge SDK behind a shared C# API for .NET MAUI / Avalonia / WinUI / desktop .NET 10 consumers.

**Architecture:** C# facade (`DVAIBridge.Shared` singleton + `IAsyncEnumerable<ProgressEvent>` progress + `ValueTask<DVAIBridgeState> GetStateAsync()` snapshot) → internal `INativeBridge` interface → `IOSNativeBridge` (calls @objc-bound `DVAIBridgeNetBridge.shared` Swift wrapper) on iOS / `AndroidNativeBridge` (calls Xamarin-bound `Co.Deepvoiceai.Bridge.NativeDVAIBridge` AAR) on Android. Reactive state surfaced via `Channel<ProgressEvent>` over native progress callbacks.

**Tech stack (latest stable as of 2026-04-27):**
- .NET 10 (10.0.7 LTS — released November 11, 2025; supported through November 14, 2028)
- `net10.0` (facade), `net10.0-ios18.0` (iOS bindings — TPV 18.7 default but pin 18.0 explicitly for binding stability), `net10.0-android36.0` (Android bindings)
- `<SupportedOSPlatformVersion>15.1</SupportedOSPlatformVersion>` for iOS runtime floor (matches Phase 3C)
- `<SupportedOSPlatformVersion>24</SupportedOSPlatformVersion>` for Android runtime floor (matches Phase 3D)
- C# 14 (`<LangVersion>latest</LangVersion>`)
- Swift 5.9+ (matches Phase 3C; the @objc wrapper compiles against the same toolchain)
- Kotlin 2.1.x (matches Phase 3D; only relevant if the optional shim is needed)
- xUnit 2.9.x (verify latest at task start) for tests; `Microsoft.NET.Test.Sdk` 17.x
- Central Package Management via `Directory.Packages.props`

**Spec:** [`docs/superpowers/specs/2026-04-27-phase3g-dotnet-package-design.md`](../specs/2026-04-27-phase3g-dotnet-package-design.md)

**Resolution of spec open questions (decided here, applied throughout):**

1. **Package structure**: split into three NuGet packages (`DVAIBridge`, `DVAIBridge.iOS`, `DVAIBridge.Android`) with TFM-conditional `<dependency>` deps in the facade's nuspec.
2. **Distribution**: NuGet.org as public packages. Family asymmetry documented in `docs/migration/v2.3-to-v2.4.md`.
3. **Streaming pattern**: `IAsyncEnumerable<ProgressEvent>` backed by `System.Threading.Channels.Channel<T>` writer.
4. **Min .NET version**: `net10.0` only (with `-ios18.0` / `-android36.0` slices). No multi-target.
5. **iOS / Android floors**: iOS 15.1, Android API 24 (matches the underlying SDKs, set via `SupportedOSPlatformVersion`).
6. **iOS bindings approach**: `@objc` Swift wrapper (`DVAIBridgeNetBridge`) + `ApiDefinition.cs` `[BaseType]` interface. Wrapper xcframework bundled inside `DVAIBridge.iOS.nupkg`.
7. **Android bindings approach**: direct AAR binding via `<AndroidLibrary>` + `Transforms/Metadata.xml`. Optional `DVAIBridgeAndroidShim.kt` only if the auto-generated `Flow<ProgressEvent>` wrapper proves unergonomic (defer to Task 4 empirics).
8. **NativeAOT**: not in v2.4 — the binding slices are not AOT-clean. Document; consumers can opt in with trim warnings.
9. **Sample app**: out of scope (per project convention). Consumer guide at `docs/guide/dotnet-sdk.md`.

**Phase boundaries:**

- **Tasks 1-2**: Package scaffold + Directory.Build.props + Directory.Packages.props + sln.
- **Task 3**: Public C# facade types (BackendKind, StartOptions, BoundServer, etc.).
- **Task 4**: Facade DVAIBridge class + INativeBridge + Channel<T>-backed IAsyncEnumerable.
- **Tasks 5-6**: iOS Swift @objc wrapper + xcframework build script.
- **Task 7**: iOS binding csproj + ApiDefinition.cs + IOSNativeBridge.cs.
- **Task 8**: Android binding csproj + Transforms/Metadata.xml + AndroidNativeBridge.cs.
- **Task 9**: Phase 3D Android AAR republish at 2.4.0 (build-graph alignment, no source changes).
- **Task 10**: xUnit unit tests on facade with mocked INativeBridge.
- **Tasks 11-12**: Docs (`dotnet-sdk.md` + migration entry) + sidebar.
- **Task 13**: CI workflow (Linux + macOS matrix; build, test, pack, dry-run push).
- **Task 14**: Version bump (2.3.0 → 2.4.0) + CHANGELOG + tag + NuGet.org publish prep.

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

## Task 1: Scaffold `dvai-bridge-dotnet` package + sln

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

## Task 2: Public C# types — records + enums + exception hierarchy

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

## Task 3: Internal `INativeBridge` interface + facade `DVAIBridge` class

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

## Task 4: Native iOS Swift `@objc` wrapper + xcframework build script

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

## Task 5: iOS bindings csproj + ApiDefinition.cs + IOSNativeBridge.cs

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

## Task 6: Android bindings csproj + Transforms/Metadata.xml + AndroidNativeBridge.cs

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

## Task 7: Phase 3D Android AAR republish at 2.4.0

**Files:**
- Update: `packages/dvai-bridge-android/android/gradle.properties` — `dvaiBridgeVersion=2.4.0` (bump from 2.3.0)
- Update: `packages/dvai-bridge-android/android/build.gradle` — bump publish version
- Update: `packages/dvai-bridge-android/CHANGELOG.md` — note "republish at 2.4.0 alongside Phase 3G .NET NuGet; no source changes"

- [ ] No Kotlin source changes; this is a build-graph alignment.
- [ ] CI re-runs the existing Android publish workflow at `v2.4.0` to push the new AAR artifact to GitHub Packages Maven.
- [ ] The .NET Android binding's CI-fetch URL (Task 6) references `2.4.0` so the build graph is internally consistent.

**Acceptance:** GitHub Packages shows `co.deepvoiceai:dvai-bridge:2.4.0` after the v2.4.0 tag is pushed (Task 14). The .NET Android binding's CI fetch step pulls the new artifact successfully.

---

## Task 8: Phase 3F Flutter podspec / pubspec re-confirmation

This is a defensive task: confirm Phase 3F's `dvai_bridge` plugin is unaffected by the .NET work (it should be — they're in different packages, different distribution systems).

- [ ] `pnpm install` from the workspace root resolves clean.
- [ ] `flutter pub get` inside `packages/dvai-bridge-flutter/` still resolves clean.
- [ ] No Phase 3F source changes; if `scripts/sync-versions.js` (extended in Task 1 / Task 14) tries to bump `dvai_bridge`'s pubspec version, manually exclude it (`dvai_bridge` stays at 2.3.0 since 3G is additive and doesn't touch Flutter).
- [ ] Document the intentional 2.3 → 2.4 jump for .NET-only in `docs/migration/v2.3-to-v2.4.md`.

**Acceptance:** Flutter package's `flutter analyze` + `flutter test` still pass at the previous commit's HEAD. No spurious Flutter changes in the v2.4.0 commit.

---

## Task 9: xUnit unit tests on facade with mocked INativeBridge

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

## Task 10: Docs — `dotnet-sdk.md` + migration entry + sidebar

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

## Task 11: CI workflow

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

## Task 12: Sync-versions / sync-package-meta extension

**Files:**
- Update: `scripts/sync-versions.js`
- Update: `scripts/sync-package-meta.js`

- [ ] `sync-versions.js`: add a handler for `Directory.Build.props` (regex on `<Version>2.3.0</Version>` → `<Version>2.4.0</Version>`). Path: `packages/dvai-bridge-dotnet/Directory.Build.props`.
- [ ] `sync-package-meta.js`: add a handler that copies `description` / `keywords` / `author` from `package.json` into the three csprojs' `<Description>` / `<PackageTags>` / `<Authors>` MSBuild properties (via Directory.Build.props or per-csproj — choose Directory.Build.props for centralization).
- [ ] Add a verification step: `node scripts/verify-cap-sync.sh` (or similar) confirms `package.json.version === Directory.Build.props.<Version>` on every commit. Extend the existing Phase 3D-3F verification harness.

**Acceptance:** Running `node scripts/sync-versions.js 2.4.0` updates `Directory.Build.props` and every other tracked file in one pass. `node scripts/sync-package-meta.js` updates the .NET csproj metadata in lockstep with the .NET package's `package.json`.

---

## Task 13: Defer-list verification (no .NET-related deferrals leaked into other phases)

This is a one-shot audit task before tag.

- [ ] Grep `docs/superpowers/specs/` and `docs/superpowers/plans/` for any TODO / FIXME / "deferred to 3G" markers in earlier phase docs. Resolve or remove.
- [ ] Audit: are there any tasks in Phase 3F's plan (or earlier) that should have addressed a .NET concern but didn't? Spot-check `2026-04-27-phase3f-flutter-package.md`. If anything is "we'll do this in 3G" → either fold it into Task 4-9 above or document explicitly as out-of-scope (Phase 4).
- [ ] Update Phase 3 foundation spec (`docs/superpowers/specs/2026-04-26-phase3-foundation-design.md`) to mark Phase 3G complete in the sub-phase position diagram.

**Acceptance:** Grep `docs/superpowers/` for `3G` / `dotnet` / `nuget` / `MAUI` returns hits only in this plan, the matching spec, the migration guide, and the foundation diagram update.

---

## Task 14: Version bump + CHANGELOG + tag + NuGet.org publish prep

**Files:**
- Update: `package.json` (root) — bump 2.3.0 → 2.4.0
- Update: `packages/dvai-bridge-dotnet/package.json` — bump 2.3.0 → 2.4.0
- Update: `packages/dvai-bridge-dotnet/Directory.Build.props` — bump 2.3.0 → 2.4.0
- Update: `packages/dvai-bridge-android/android/gradle.properties` — already 2.4.0 from Task 7
- Update: `packages/dvai-bridge-dotnet/CHANGELOG.md` — release entry
- Update: `CHANGELOG.md` (root) — `## [2.4.0] — YYYY-MM-DD` covering the .NET package + Android AAR republish
- Update: `PUBLISHING.md` (gitignored) — add `dotnet nuget push` step for `DVAIBridge` + `DVAIBridge.iOS` + `DVAIBridge.Android` (the only NuGet.org publish in the family)

- [ ] Run `node scripts/sync-versions.js` + `node scripts/sync-package-meta.js`. Confirm `Directory.Build.props`'s `<Version>` is now in the version-tracker's known files (Task 12).
- [ ] CHANGELOG entry under `## [2.4.0] — YYYY-MM-DD`:
  - Added: .NET NuGet package family `DVAIBridge` + `DVAIBridge.iOS` + `DVAIBridge.Android` (NuGet.org) — .NET 10 LTS, single facade with TFM-conditional iOS/Android slices, idiomatic `IAsyncEnumerable<ProgressEvent>` reactive surface.
  - Changed: Phase 3D Android AAR republished at 2.4.0 for build-graph alignment (no source changes).
  - Notes: .NET packages published to NuGet.org (vs the Maven/npm GitHub-Packages part of the family); see `docs/migration/v2.3-to-v2.4.md`.
- [ ] PUBLISHING.md flow:
  1. `git tag v2.4.0` + push
  2. CI publishes the Android AAR to GitHub Packages
  3. CI builds the iOS xcframework + packs three NuGets on macos-latest
  4. CI runs `dotnet nuget push ./out/*.nupkg --source https://api.nuget.org/v3/index.json --api-key ${{ secrets.NUGET_API_KEY }} --skip-duplicate` (guarded by tag trigger)
  5. Verify NuGet.org pages at https://www.nuget.org/packages/DVAIBridge / .iOS / .Android show 2.4.0 within ~10 minutes (NuGet.org indexing latency)
- [ ] Commit + tag `v2.4.0` + push.

**Acceptance:**
- `pnpm install` succeeds at 2.4.0.
- `bash scripts/verify-cap-sync.sh` exits 0 (existing script must tolerate the new csproj/Directory.Build.props; confirm or extend).
- `git tag --list | grep v2.4.0` shows the new tag.
- `dotnet pack` from the solution root produces three `.nupkg` + three `.snupkg` files at version 2.4.0.
- A test `dotnet nuget push --no-symbols` (no `--api-key`, expect auth failure not validation failure) confirms the package format is acceptable.

---

## Test strategy summary

| Layer                       | Tool                                       | Where                                              |
|-----------------------------|--------------------------------------------|----------------------------------------------------|
| C# unit tests (facade)      | `dotnet test` + xUnit + Moq + Coverlet     | `packages/dvai-bridge-dotnet/tests/DVAIBridge.Tests/` |
| Static analysis             | `dotnet build` with `<TreatWarningsAsErrors>` + nullable | per-csproj; CI workflow             |
| iOS binding sanity          | `dotnet build src/DVAIBridge.iOS -c Release` | CI macos runner (Task 11)                        |
| Android binding sanity      | `dotnet build src/DVAIBridge.Android -c Release` | CI ubuntu runner (Task 11)                  |
| iOS xcframework build       | `bash build-xcframework.sh`                | CI macos runner (Task 11)                          |
| Pack dry-run                | `dotnet pack -c Release -o ./out`          | CI macos runner (Task 11)                          |
| End-to-end runtime          | .NET MAUI demo app (consumer-side)         | docs only — scripted per project convention        |
| NuGet.org publish dry-run   | `dotnet nuget push --no-symbols` (no key)  | CI tag-push (Task 11) — auth-fail is the success signal |
| Coverage reporting          | Coverlet → XPlat Code Coverage             | CI artifact upload                                 |

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

## Out-of-scope

- WinUI 3 / Avalonia / desktop native backends (Phase 4+).
- Mac Catalyst / tvOS / watchOS targets (Phase 4+).
- Xamarin.Forms / classic Xamarin.iOS / classic Xamarin.Android targets (EOL since 2024).
- F# / VB.NET-specific API surface (works via standard CLR interop).
- NativeAOT-clean binding slices (Phase 4 candidate).
- Source generators / Roslyn analyzers for backend-platform-mismatch (runtime check is sufficient for v2.4).
- `IObservable<T>` first-class API (Rx interop one-liner is sufficient).
- GitHub Packages NuGet feed (NuGet.org chosen; see spec §4.1).
- Sample app source — scripted only (per project convention).
- iOS / Android source changes beyond the AAR republish at 2.4.0 (Task 7).
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
