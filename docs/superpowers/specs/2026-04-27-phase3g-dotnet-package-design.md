# Phase 3G — .NET NuGet Packages (`DVAIBridge.Net` family)

**Status:** Revised — mobile-only slice implemented (v2.4.0-rc1); desktop + ONNX + ML.NET expansion in progress
**Date:** 2026-04-27 (initial) / 2026-04-27 (rev 2 — desktop + .NET-specific backends)
**Scope:** A unified .NET NuGet package family that wraps the Phase 3C iOS Native SDK + Phase 3D Android Native SDK + a new desktop slice (Windows / macOS / Linux via `llama.cpp` P/Invoke + Kestrel) + two .NET-specific backends (ONNX Runtime, ML.NET) behind a single managed C# API. Drop-in for any .NET 10 (LTS, current) consumer — .NET MAUI, Avalonia, Xamarin (legacy), WinUI 3, console / server — that needs a local LLM with an OpenAI-compatible HTTP endpoint. Mobile slices: zero managed-side inference engine, binding-layer P/Invoke only into the existing Swift / Kotlin SDKs. Desktop slice: thin C# host around `llama.cpp` with `[DllImport]` from RID-specific natives. ONNX / ML.NET slices: pure-managed wrappers around Microsoft's first-party NuGet packages.

## Revision history

| Date       | Rev | Author    | Notes                                                                                                                                                                                                                                                                                                                                                                          |
|------------|-----|-----------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 2026-04-27 | 1   | dchak     | Initial spec — iOS + Android slices only. Implemented as v2.4.0-rc1 (Tasks 1–13 of the plan).                                                                                                                                                                                                                                                                                  |
| 2026-04-27 | 2   | dchak     | Scope expansion driven by user review of mobile-only build: (a) desktop is high priority (.NET MAUI / Avalonia / WinUI consumers run primarily on Windows; falling through to `UnsupportedPlatformBridge` is a terrible first NuGet impression — 5/6 facade test failures in v2.4.0-rc1 are exactly this gap), (b) two .NET-specific backends were missing — ONNX Runtime and ML.NET — both of which Microsoft ships first-party NuGets for. Adds `DVAIBridge.Desktop`, `DVAIBridge.OnnxRuntime`, `DVAIBridge.MLNet` packages; adds Mac Catalyst as a multi-target TFM in the existing iOS slice csproj; expands `BackendKind` from 7 to 9 cases (`Onnx`, `MLNet`); revises effort estimate from ~3 days to ~12 days. Other wrappers (iOS / Android / RN / Flutter) do **not** gain ONNX / MLNet cases — these are .NET-specific backends per the user's framing ("those were specific to dotnet"). See §6 Q11–Q13 for the new decisions. |

**Sub-phase position in Phase 3:**

```
3A core extraction ✅ → 3B LiteRT-LM migration ✅ → 3C iOS SDK ✅
                                                  → 3D Android AAR ✅
                                                  → 3E React Native ✅
                                                  → 3F Flutter ✅
                                                  → 3G .NET NuGet ◀️ YOU ARE HERE
                                                  → 3H docs / publish / launch
```

3G is the final platform-bridging package before launch. Like 3E (RN) and 3F (Flutter), the underlying SDKs already speak the same `DVAIBridge` shape (8-method singleton + reactive state). 3G wraps them in idiomatic C# (`Task<T>` for async, `IAsyncEnumerable<T>` for progress streams, sealed exception hierarchy) and ships to NuGet so .NET MAUI / Avalonia / WinUI consumers can `dotnet add package DVAIBridge` and point any OpenAI-compatible HTTP client (e.g. `Microsoft.SemanticKernel.Connectors.OpenAI`, `OpenAI` official .NET SDK, `RestSharp`) at `http://127.0.0.1:<port>/v1`.

---

## 1. Goals

1. Stand up `packages/dvai-bridge-dotnet/` — **six NuGet packages** in a single solution, published from a single tag:
   - `DVAIBridge` — the managed facade (TFM `net10.0`).
   - `DVAIBridge.iOS` — iOS bindings + `@objc` Swift wrapper xcframework. Multi-targets `net10.0-ios18.0` and `net10.0-maccatalyst18.0` (free reuse of the same Swift xcframework — see §3.2 / §6 Q12).
   - `DVAIBridge.Android` — Android bindings against the Phase 3D AAR.
   - `DVAIBridge.Desktop` — Llama-only desktop slice (`net10.0`) with RID-specific `llama.cpp` natives for `win-x64`, `win-arm64`, `osx-x64`, `osx-arm64`, `linux-x64`, `linux-arm64`.
   - `DVAIBridge.OnnxRuntime` — ONNX Runtime backend (cross-platform: desktop + mobile). Wraps `Microsoft.ML.OnnxRuntime` 1.25.0 + `Microsoft.ML.OnnxRuntimeGenAI` 0.13.1.
   - `DVAIBridge.MLNet` — ML.NET backend (desktop primary; iOS/Android limited). Wraps `Microsoft.ML` 5.0.0 + `Microsoft.ML.OnnxTransformer`.

   Single `using DVAIBridge;` import for consumers regardless of platform / backend; the platform slices and backend slices are pulled in transitively by TFM-conditional and explicit `<PackageReference>` entries (consumers explicitly add `DVAIBridge.OnnxRuntime` / `DVAIBridge.MLNet` if they want those backends — they aren't auto-pulled like the iOS/Android slices, since they're consumer-opt-in extensions, not platform requirements).
2. Public C# API mirrors the iOS / Android shape with idiomatic .NET conventions:
   ```csharp
   using DVAIBridge;

   var server = await DVAIBridge.Shared.StartAsync(new StartOptions
   {
       Backend = BackendKind.Auto,
       ModelPath = "/path/to/model.gguf",
   });
   Console.WriteLine(server.BaseUrl); // http://127.0.0.1:38883/v1
   await DVAIBridge.Shared.StopAsync();
   ```
3. Two thin native binding projects in the same solution (unified package layout, see §3.1):
   - **iOS bindings** (`DVAIBridge.iOS`, `net10.0-ios18.0`): a Swift wrapper class (`DVAIBridgeNetBridge`) that re-exports `DVAIBridge.shared`'s API surface as `@objc`-annotated methods + an `ApiDefinition.cs` `[BaseType]` interface that describes the resulting Obj-C contract. The Swift wrapper depends on `DVAIBridge` (the SwiftPM target from Phase 3C v2.3+); the binding project consumes the framework via `NativeReference` MSBuild item.
   - **Android bindings** (`DVAIBridge.Android`, `net10.0-android36.0`): an `<AndroidLibrary>` reference to `co.deepvoiceai:dvai-bridge:2.4.0` (Phase 3D umbrella AAR — bumped to 2.4.0 alongside this package) plus `Transforms/Metadata.xml` rules to map Kotlin coroutines (`suspend fun`) onto idiomatic C# `Task<T>` signatures.
4. Cross-platform `BackendKind` is the **union** of all platform + .NET-specific cases (9 values, expanded from 7 in rev 1):
   ```csharp
   public enum BackendKind {
       Auto       = 0,
       Llama      = 1,  // every platform that has a slice (iOS / Android / Catalyst / Desktop)
       Foundation = 2,  // iOS / Catalyst only
       CoreML     = 3,  // iOS / Catalyst only
       MLX        = 4,  // iOS / Catalyst only
       MediaPipe  = 5,  // Android only
       LiteRT     = 6,  // Android only
       Onnx       = 7,  // .NET-specific — every platform via Microsoft.ML.OnnxRuntime
       MLNet      = 8,  // .NET-specific — desktop primary, mobile best-effort
   }
   ```
   `BackendKindExtensions.ToWireString` / `FromWireString` add the two new values (`"onnx"`, `"mlnet"`). The facade pre-validates against the runtime platform via `PlatformBridgeFactory` (`OperatingSystem.IsIOS()` / `IsAndroid()` / `IsWindows()` / `IsLinux()` / `IsMacOS()` / `IsMacCatalyst()`); native bindings are still authoritative and throw `DVAIBridgeException(Kind: BackendUnavailable)` if a consumer somehow bypasses the facade. The platform availability matrix is in §3.8.

   **Cross-family scope** (resolved §6 Q11): `Onnx` and `MLNet` are **.NET-specific** — they do **not** appear in the iOS / Android / RN / Flutter wrappers' `BackendKind` enums (which stay at 7 values: Auto / Llama / Foundation / CoreML / MLX / MediaPipe / LiteRT). The asymmetry is documented in `docs/guide/dotnet-sdk.md`.
5. Reactive state surface: `IAsyncEnumerable<ProgressEvent> ProgressEvents` + a `ValueTask<DVAIBridgeState> GetStateAsync()` snapshot helper. `IAsyncEnumerable<T>` is the idiomatic modern .NET stream — composes with `await foreach`, `System.Linq.Async`, `IAsyncEnumerable<T>.WithCancellation(token)`, and (via `Reactive.Linq.AsyncEnumerable`) Rx if a consumer prefers it. **Polling-free.**
6. Build pipeline: C# source → `dotnet build` clean under `<TreatWarningsAsErrors>true</TreatWarningsAsErrors>` and `<Nullable>enable</Nullable>`. iOS Swift wrapper builds via xcodebuild + Sharpie + `dotnet build` of the binding csproj (CI macos-latest runner). Android binding builds Linux-only (CI ubuntu-latest runner with Android workload installed).

## 2. Non-goals (3G)

> **Rev 2 update**: native desktop (Llama via llama.cpp) and Mac Catalyst are now **in-scope** — see §3.5 (Desktop slice) and §3.2 (Catalyst as a multi-target TFM in `DVAIBridge.iOS.csproj`). The non-goals below are post-revision.

- **GPU acceleration on Linux/Windows desktop** — the desktop `llama.cpp` build uses CPU-only natives in v2.4 (Vulkan / CUDA / ROCm builds add a CI matrix dimension we don't want for the first ship). Document; revisit in 2.5+.
- **iOS/Android-side ML.NET** — `Microsoft.ML` formally supports `net*-ios` and `net*-android` TFMs but the runtime story is fragile (no GPU, slow CPU inference, large IL footprint). `DVAIBridge.MLNet` advertises desktop-only support; mobile callers requesting `BackendKind.MLNet` get `BackendUnavailable` with a "use BackendKind.Onnx / Llama on mobile instead" hint. Revisit in 2.5 if real-world demand materializes.
- **tvOS, watchOS, browser-wasm** — out of scope. The iOS bindings target `net10.0-ios18.0` + `net10.0-maccatalyst18.0` only. tvOS/watchOS would require additional Swift wrapper builds and have no realistic LLM use case yet. Browser-wasm is incompatible with both `llama.cpp` and ONNX Runtime's WebAssembly story (different SIMD constraints).
- **Xamarin.Forms / classic Xamarin.iOS / Xamarin.Android** — EOL since May 2024. We don't add `xamarin*` TFMs. .NET 10 MAUI consumers and pre-MAUI .NET 8/9 iOS/Android consumers are supported via TFM compatibility (binding projects are compatible with `net8.0-android` / `net8.0-ios` consumers via reference assembly precedence).
- **Self-hosted llama.cpp build farm** — we use upstream llama.cpp **release tag `b8946`** (2026-04-27) prebuilt binaries from GitHub Releases for the desktop natives, not a from-source build per RID. Saves the cross-compile matrix; trades off "we can't carry custom patches" (acceptable: we don't have any). See §3.5.4.
- **Sample app project in the solution** — out of scope (per the project's "scripted samples" convention). Docs include a copy-paste-ready snippet and the consumer guide is a `docs/guide/dotnet-sdk.md` page.
- **Source generators / Roslyn analyzers for backend-platform-mismatch detection** — nice to have but adds significant complexity; runtime check + clear error message is sufficient for v2.4.
- **F# / VB.NET-specific surface** — the C# API works from F# and VB.NET via standard CLR interop. We don't ship F#-idiomatic computation expressions or VB-friendly overloads.
- **NativeAOT-attributed library** — the binding projects rely on dynamic Obj-C / JNI marshalling that's not (yet) NativeAOT-clean. Consumers can still use NativeAOT for their app, but the `DVAIBridge.iOS` / `.Android` packages are linked in with `<TrimMode>partial</TrimMode>` and ship without `IsAotCompatible=true`. Document; revisit in Phase 4.
- **`IObservable<T>` / Rx.NET API surface** — see §6 for the IAsyncEnumerable-vs-IObservable decision.
- **GitHub Packages NuGet feed** — see §4 for the NuGet.org-vs-GitHub-Packages decision (we go NuGet.org, joining `dvai_bridge` on pub.dev as the second public family member).

## 3. Architecture

### 3.1 Package layout

```
packages/dvai-bridge-dotnet/
├── package.json                               # @dvai-bridge/dotnet — npm-graph integration only
│                                              # (no actual npm publish; lets pnpm-workspace see the dir)
├── DVAIBridge.sln                             # solution
├── README.md                                  # synced via scripts/sync-package-meta.js
├── CHANGELOG.md
├── Directory.Build.props                      # repo-wide MSBuild defaults
│                                              #   (LangVersion latest, Nullable enable,
│                                              #   TreatWarningsAsErrors true, version 2.4.0)
├── Directory.Packages.props                   # central package management
│                                              #   (CPM/CentralPackageManagement enabled)
├── src/
│   ├── DVAIBridge/                            # facade — net10.0 (no platform suffix)
│   │   ├── DVAIBridge.csproj
│   │   ├── DVAIBridge.cs                      # singleton-ish class with Start/Stop/Status/Download
│   │   ├── BackendKind.cs                     # enum
│   │   ├── StartOptions.cs                    # record
│   │   ├── BoundServer.cs                     # record
│   │   ├── StatusInfo.cs                      # record
│   │   ├── DownloadOptions.cs                 # record
│   │   ├── DownloadResult.cs                  # record
│   │   ├── DVAIBridgeException.cs             # sealed exception hierarchy
│   │   ├── ProgressEvent.cs                   # record + ProgressKind / ProgressPhase enums
│   │   ├── DVAIBridgeState.cs                 # record
│   │   ├── INativeBridge.cs                   # internal — implementations live in iOS/Android slices
│   │   └── PlatformBridgeFactory.cs           # internal — RuntimeFeature.IsSupported guards
│   ├── DVAIBridge.iOS/                        # net10.0-ios18.0 + net10.0-maccatalyst18.0 (multi-target — see §3.2)
│   │   ├── DVAIBridge.iOS.csproj              # IsBindingProject=true, NativeReference Swift xcframework
│   │   ├── ApiDefinition.cs                   # [BaseType] DVAIBridgeNetBridge contract
│   │   ├── StructsAndEnums.cs                 # bound enum bridge + struct mappings
│   │   ├── IOSNativeBridge.cs                 # internal — implements INativeBridge by calling Obj-C bindings
│   │   └── native/
│   │       ├── DVAIBridgeNetBridge.swift      # tiny Swift wrapper around DVAIBridge.shared with @objc surface
│   │       ├── Package.swift                  # SwiftPM manifest for the wrapper module (CI builds the xcframework)
│   │       └── build-xcframework.sh           # CI build helper (xcodebuild -create-xcframework, ios + ios-sim + maccatalyst slices)
│   ├── DVAIBridge.Android/                    # net10.0-android36.0 binding + Kotlin shim
│   │   ├── DVAIBridge.Android.csproj          # IsBindingProject=true, AndroidLibrary AAR ref
│   │   ├── Transforms/
│   │   │   ├── Metadata.xml                   # mapping rules (suspend → Task, package rename, etc.)
│   │   │   └── EnumFields.xml                 # BackendKind enum value mapping
│   │   ├── AndroidNativeBridge.cs             # internal — implements INativeBridge by calling generated bindings
│   │   └── native/
│   │       ├── DVAIBridgeAndroidShim.kt       # optional Kotlin coroutine→callback adapter (only if metadata can't do it)
│   │       └── build.gradle                   # AAR build (delegates to Phase 3D umbrella)
│   ├── DVAIBridge.Desktop/                    # net10.0 + RID-specific llama.cpp natives (NEW — rev 2)
│   │   ├── DVAIBridge.Desktop.csproj          # PackageType=Dependency, RuntimeIdentifiers=win-x64;win-arm64;osx-x64;osx-arm64;linux-x64;linux-arm64
│   │   ├── DesktopNativeBridge.cs             # internal — implements INativeBridge using Llama P/Invoke + Kestrel
│   │   ├── LlamaNative.cs                     # internal — [DllImport("llama")] declarations matching llama.cpp's C API
│   │   ├── LlamaServer.cs                     # internal — Kestrel ASP.NET Core minimal-API host exposing /v1/* (mirrors iOS / Android exactly)
│   │   ├── runtimes/                          # native binaries (gitignored; fetched by CI from llama.cpp release b8946)
│   │   │   ├── win-x64/native/llama.dll
│   │   │   ├── win-arm64/native/llama.dll
│   │   │   ├── osx-x64/native/libllama.dylib
│   │   │   ├── osx-arm64/native/libllama.dylib
│   │   │   ├── linux-x64/native/libllama.so
│   │   │   └── linux-arm64/native/libllama.so
│   │   └── scripts/
│   │       ├── fetch-llama-binaries.sh        # Downloads llama.cpp b8946 release artifacts per RID
│   │       └── verify-llama-checksums.sh      # SHA256-pins each native against a checked-in manifest
│   ├── DVAIBridge.OnnxRuntime/                # net10.0 (cross-platform via ORT NuGet's TFM-conditional natives) (NEW — rev 2)
│   │   ├── DVAIBridge.OnnxRuntime.csproj      # PackageReference Microsoft.ML.OnnxRuntime 1.25.0 + Microsoft.ML.OnnxRuntimeGenAI 0.13.1
│   │   ├── OnnxNativeBridge.cs                # internal — implements INativeBridge via OrtSession + Kestrel host
│   │   ├── OnnxGenAIRunner.cs                 # internal — wraps OnnxRuntimeGenAI's Generator API for streaming token output
│   │   └── OnnxServer.cs                      # internal — Kestrel /v1/* endpoints, OpenAI-compatible
│   ├── DVAIBridge.MLNet/                      # net10.0 (desktop primary; mobile best-effort) (NEW — rev 2)
│   │   ├── DVAIBridge.MLNet.csproj            # PackageReference Microsoft.ML 5.0.0 + Microsoft.ML.OnnxTransformer 5.0.0
│   │   ├── MLNetNativeBridge.cs               # internal — implements INativeBridge via MLContext + ONNX transformer
│   │   └── MLNetServer.cs                     # internal — Kestrel /v1/* endpoints
│   └── shared/                                # net10.0 internal-only — Kestrel host + OpenAI-compat surface, used by Desktop / Onnx / MLNet
│       └── DVAIBridge.Shared.Hosting/
│           ├── DVAIBridge.Shared.Hosting.csproj  # internal facade-shared project; not packed into NuGet (sources linked into each backend)
│           ├── OpenAIServer.cs                # generic Kestrel host with /v1/chat/completions, /v1/completions, /v1/embeddings, /v1/models
│           ├── PortPicker.cs                  # binds 127.0.0.1, walks HttpBasePort .. HttpBasePort+HttpMaxPortAttempts
│           └── IInferenceEngine.cs            # 1-method internal interface backends implement (Generate(prompt, …) → IAsyncEnumerable<Token>)
└── tests/
    ├── DVAIBridge.Tests/                      # xUnit tests on the facade with INativeBridge mocked (existing — Tasks 1–13)
    │   ├── DVAIBridge.Tests.csproj            # net10.0
    │   ├── DVAIBridgeFacadeTests.cs
    │   ├── BackendKindValidationTests.cs
    │   ├── ProgressEventStreamTests.cs
    │   └── PlatformExceptionMappingTests.cs
    ├── DVAIBridge.Desktop.Tests/              # NEW — rev 2; xUnit on Windows + Linux + macOS CI runners
    │   ├── DVAIBridge.Desktop.Tests.csproj    # net10.0
    │   ├── DesktopNativeBridgeTests.cs        # P/Invoke smoke + Kestrel HTTP /v1 round-trip with a tiny TinyLlama 1.1B Q4_0 fixture
    │   └── PortPickerTests.cs
    ├── DVAIBridge.OnnxRuntime.Tests/          # NEW — rev 2
    │   ├── DVAIBridge.OnnxRuntime.Tests.csproj
    │   └── OnnxNativeBridgeTests.cs           # uses a tiny ONNX classifier fixture for the smoke; GenAI streaming smoke uses Phi-3-mini-4k-instruct-onnx-int4 (small enough to ship in CI)
    └── DVAIBridge.MLNet.Tests/                # NEW — rev 2
        ├── DVAIBridge.MLNet.Tests.csproj
        └── MLNetNativeBridgeTests.cs          # MLContext load smoke + ONNX-transformer pipeline smoke
```

### 3.2 Public API surface (C#)

```csharp
using DVAIBridge;

// Lifecycle
var server = await DVAIBridge.Shared.StartAsync(new StartOptions
{
    Backend = BackendKind.Auto,
    ModelPath = "/path/to/model.gguf",
    ContextSize = 2048,
    Threads = 4,
});

Console.WriteLine(server.BaseUrl);   // http://127.0.0.1:38883/v1
Console.WriteLine(server.Port);      // 38883
Console.WriteLine(server.Backend);   // BackendKind.Llama
Console.WriteLine(server.ModelId);

var status = await DVAIBridge.Shared.GetStatusAsync();
await DVAIBridge.Shared.StopAsync();

// Reactive state — IAsyncEnumerable<ProgressEvent>, idiomatic await foreach.
await foreach (var ev in DVAIBridge.Shared.ProgressEvents.WithCancellation(ct))
{
    Console.WriteLine($"{ev.Kind} {ev.Phase} {ev.Percent}");
}

// Snapshot — useful for "is the bridge currently running?" checks.
var state = await DVAIBridge.Shared.GetStateAsync();
if (state.IsReady) {
    var openAi = new OpenAIClient(new Uri(state.BaseUrl!), apiKey: "local-stub");
    // ... use any OpenAI-compatible .NET SDK against the local server.
}
```

`DVAIBridge` is a sealed class with a static `Shared` property (singleton) backed by `Lazy<DVAIBridge>`. The constructor stays `internal` for production use but exposes a `[InternalsVisibleTo("DVAIBridge.Tests")]` hatch and an `internal DVAIBridge(INativeBridge bridge)` test-seam constructor (mirrors the iOS-side test-isolation pattern of constructing a fresh `DVAIBridge()` actor).

### 3.3 Bindings layer sketch — iOS / Mac Catalyst

The Swift wrapper (`DVAIBridgeNetBridge.swift`) re-exports the `DVAIBridge` API as an `NSObject` subclass with `@objc` methods:

```swift
import DVAIBridge
import Foundation
import Combine

@objc(DVAIBridgeNetBridge)
public final class DVAIBridgeNetBridge: NSObject {
    @objc public static let shared = DVAIBridgeNetBridge()

    @objc public func start(
        config: NSDictionary,
        completion: @escaping (NSDictionary?, NSError?) -> Void
    ) {
        Task {
            do {
                let cfg = try DVAIBridgeConfig.fromNSDictionary(config)
                let server = try await DVAIBridge.shared.start(cfg)
                completion(server.toNSDictionary(), nil)
            } catch let e as DVAIBridgeError {
                completion(nil, e.toNSError())
            } catch {
                completion(nil, error as NSError)
            }
        }
    }

    @objc public func stop(completion: @escaping (NSError?) -> Void) { /* ... */ }
    @objc public func status(completion: @escaping (NSDictionary?, NSError?) -> Void) { /* ... */ }
    @objc public func downloadModel(
        options: NSDictionary,
        completion: @escaping (NSDictionary?, NSError?) -> Void
    ) { /* ... */ }

    @objc public func subscribeProgress(
        onEvent: @escaping (NSDictionary) -> Void
    ) -> NSObject /* opaque cancellable handle */ { /* tap progressPublisher */ }
}
```

The CI build (`build-xcframework.sh`) wraps it as an `xcframework` with three slices — `ios-arm64` (device), `ios-arm64_x86_64-simulator` (sim universal), and `ios-arm64_x86_64-maccatalyst` (Catalyst universal). `DVAIBridge.iOS.csproj` is multi-target (`net10.0-ios18.0;net10.0-maccatalyst18.0`) and consumes the same xcframework on both TFMs:

```xml
<PropertyGroup>
  <TargetFrameworks>net10.0-ios18.0;net10.0-maccatalyst18.0</TargetFrameworks>
  <SupportedOSPlatformVersion Condition="'$(TargetFramework)' == 'net10.0-ios18.0'">15.1</SupportedOSPlatformVersion>
  <SupportedOSPlatformVersion Condition="'$(TargetFramework)' == 'net10.0-maccatalyst18.0'">15.1</SupportedOSPlatformVersion>
</PropertyGroup>
<ItemGroup>
  <NativeReference Include="native/DVAIBridgeNetBridge.xcframework">
    <Kind>Framework</Kind>
    <SmartLink>True</SmartLink>
    <ForceLoad>True</ForceLoad>
  </NativeReference>
</ItemGroup>
```

The Phase 3C SwiftPM package already declares `.platforms = [.iOS(.v15_1), .macCatalyst(.v15_1)]` (verified against `packages/dvai-bridge-ios/Package.swift`); the Catalyst slice is free to add — same Swift sources, same xcframework, same `IOSNativeBridge.cs` implementation. The runtime fork is in `PlatformBridgeFactory.Create()` which checks `OperatingSystem.IsMacCatalyst()` and routes to the same `IOSNativeBridge` instance. See §6 Q12 for why we chose multi-target over a separate `DVAIBridge.MacCatalyst` NuGet.

`ApiDefinition.cs` describes the resulting Obj-C contract for the C# binding generator:

```csharp
using Foundation;
using ObjCRuntime;

namespace DVAIBridge.iOS.Native;

[BaseType(typeof(NSObject))]
[DisableDefaultCtor]
interface DVAIBridgeNetBridge
{
    [Static, Export("shared")]
    DVAIBridgeNetBridge Shared { get; }

    [Async]
    [Export("start:completion:")]
    void Start(NSDictionary config, Action<NSDictionary, NSError> completion);

    [Async]
    [Export("stop:")]
    void Stop(Action<NSError> completion);

    // ... etc.
}
```

The `[Async]` attribute generates a `Task<NSDictionary>`-returning C# overload alongside the completion-handler form. `IOSNativeBridge.cs` (internal to the assembly) translates between the bound `NSDictionary` payloads and the public `StartOptions` / `BoundServer` records, then exposes itself as `INativeBridge` to the facade.

This pattern follows Microsoft's [Native Library Interop](https://devblogs.microsoft.com/dotnet/native-library-interop-dotnet-maui/) guidance — bind a small Swift `@objc` wrapper rather than trying to bind the full Swift API surface directly (Swift's name-mangled symbols + advanced features like generics, actors, and protocols-with-associated-types don't expose to Obj-C).

### 3.4 Bindings layer sketch — Android

The Android binding consumes the existing `co.deepvoiceai:dvai-bridge:2.4.0` AAR directly (no shim layer needed in most cases — the AAR's public API is already Java-friendly):

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0-android36.0</TargetFramework>
    <SupportedOSPlatformVersion>24</SupportedOSPlatformVersion>
    <IsBindingProject>true</IsBindingProject>
    <AndroidClassParser>class-parse</AndroidClassParser>
    <AndroidCodegenTarget>XAJavaInterop1</AndroidCodegenTarget>
  </PropertyGroup>
  <ItemGroup>
    <AndroidLibrary Include="$(MSBuildThisFileDirectory)../../node_modules/.cache/dvai-bridge.aar">
      <Bind>true</Bind>
    </AndroidLibrary>
    <TransformFile Include="Transforms/Metadata.xml" />
    <TransformFile Include="Transforms/EnumFields.xml" />
  </ItemGroup>
</Project>
```

`Transforms/Metadata.xml` maps Kotlin's `suspend fun` continuation-passing-style to idiomatic C# `Task<T>`:

```xml
<metadata>
  <!-- Kotlin compiler generates `start(config, kotlin.coroutines.Continuation)` -->
  <!-- The Java binding generator then exposes start(config, Continuation) which we rewrite. -->
  <attr path="/api/package[@name='co.deepvoiceai.bridge']/class[@name='DVAIBridge']/method[@name='start']"
        name="managedReturn">System.Threading.Tasks.Task&lt;BoundServer&gt;</attr>
  <!-- Rename the Java-style "DVAIBridge" object to "NativeDVAIBridge" so the C# facade -->
  <!-- can keep using "DVAIBridge" for its public class without a name collision. -->
  <attr path="/api/package[@name='co.deepvoiceai.bridge']/class[@name='DVAIBridge']"
        name="managedName">NativeDVAIBridge</attr>
</metadata>
```

`AndroidNativeBridge.cs` (internal) calls the bound `Co.Deepvoiceai.Bridge.NativeDVAIBridge.Start(config, ...)` and converts the Kotlin types → public records, and exposes itself as `INativeBridge`.

If the metadata-only approach hits a Kotlin coroutine wall (e.g., `Flow<ProgressEvent>` doesn't map cleanly), `native/DVAIBridgeAndroidShim.kt` provides a thin callback-style adapter compiled into a thin AAR alongside the umbrella; the binding then wraps the shim instead. We default to metadata-only and add the shim only if needed (Task 4 of the plan).

### 3.5 Desktop slice — `DVAIBridge.Desktop` (Llama via P/Invoke + Kestrel)

Targets `net10.0` (no platform suffix) with `<RuntimeIdentifiers>win-x64;win-arm64;osx-x64;osx-arm64;linux-x64;linux-arm64</RuntimeIdentifiers>`. The NuGet package's `runtimes/<rid>/native/` directory carries one prebuilt `llama.cpp` shared library per RID; .NET's restore logic resolves the right one per consumer's `RuntimeIdentifier` automatically.

#### 3.5.1 Native binary sourcing — upstream `llama.cpp` release artifacts

We pull from `ggerganov/llama.cpp` **release tag `b8946`** (released 2026-04-27, the latest stable at this revision). The release ships a pre-built tarball per RID:

| RID            | Release artifact                                                | Library file       |
|----------------|-----------------------------------------------------------------|--------------------|
| `win-x64`      | `llama-b8946-bin-win-cpu-x64.zip`                               | `llama.dll`        |
| `win-arm64`    | `llama-b8946-bin-win-cpu-arm64.zip`                             | `llama.dll`        |
| `osx-x64`      | `llama-b8946-bin-macos-x64.zip`                                 | `libllama.dylib`   |
| `osx-arm64`    | `llama-b8946-bin-macos-arm64.zip`                               | `libllama.dylib`   |
| `linux-x64`    | `llama-b8946-bin-ubuntu-x64.zip`                                | `libllama.so`      |
| `linux-arm64`  | `llama-b8946-bin-ubuntu-arm64.zip` (cross-built; if upstream lacks an arm64 build for this tag, we fall back to building from source on a Linux ARM64 GitHub Actions runner — see §3.5.4) | `libllama.so` |

`scripts/fetch-llama-binaries.sh` (CI helper) downloads each archive, extracts the shared library + `ggml*.so/.dll/.dylib` siblings, and writes them under `src/DVAIBridge.Desktop/runtimes/<rid>/native/`. SHA256 checksums are pinned in `scripts/llama-checksums.txt` and verified before pack.

**Why prebuilts over from-source per-RID**: the cross-compile matrix (Mac → Windows via mingw, Mac → Linux via NDK / Linux toolchain in Docker, Linux ARM64 cross-build) is a 2–3 day setup that we don't need — upstream's CI already produces the binaries we want, and we have no patches to carry. Phase 4+ revisits if we need custom kernels (e.g. Vulkan, CUDA, ROCm, MoE-specific tunings).

#### 3.5.2 P/Invoke surface — `LlamaNative.cs`

Thin `[DllImport("llama")]` declarations matching `llama.cpp`'s C API (the stable subset — `llama_load_model_from_file`, `llama_new_context_with_model`, `llama_decode`, `llama_token_get_text`, `llama_sample_token_*`, `llama_model_free`, `llama_free`). The `[DllImport("llama")]` library name resolves to `llama.dll` on Windows, `libllama.dylib` on macOS, `libllama.so` on Linux automatically per .NET's [DllImport name resolution](https://learn.microsoft.com/en-us/dotnet/standard/native-interop/cross-platform).

Custom `NativeLibrary.SetDllImportResolver` hook handles the `runtimes/<rid>/native/` lookup at startup so the resolved path is the NuGet-shipped binary, not whatever happens to be on the consumer's `PATH` / `DYLD_LIBRARY_PATH` / `LD_LIBRARY_PATH`. Pattern matches Microsoft's own approach in `Microsoft.ML.OnnxRuntime.Native.cs`.

#### 3.5.3 Kestrel HTTP host — `LlamaServer.cs`

Embeds an ASP.NET Core minimal-API host bound to `127.0.0.1:<port>` with the same OpenAI-compatible surface every other DVAIBridge slice exposes:

- `POST /v1/chat/completions` (streaming via SSE if `stream: true`)
- `POST /v1/completions` (legacy completions API for non-chat models)
- `POST /v1/embeddings` (embedding mode — only if `StartOptions.EmbeddingMode = true`)
- `GET /v1/models` (returns the single bound model's id)

Reuses the **internal** `DVAIBridge.Shared.Hosting` source-only project (sources linked into Desktop / Onnx / MLNet csprojs via `<Compile Include="..\shared\..."/>` rather than a published NuGet — keeps the per-backend nupkg self-contained and removes a diamond-dep risk). The `IInferenceEngine` interface backends implement is one method:

```csharp
internal interface IInferenceEngine : IAsyncDisposable
{
    IAsyncEnumerable<string> GenerateAsync(string prompt, GenerationOptions opts, CancellationToken ct);
}
```

`OpenAIServer.cs` adapts that one method to all four endpoints (chat-completions vs completions is a prompt-formatting + response-shape difference, not a different inference path; embeddings is a separate `IEmbeddingEngine` capability backends opt into).

#### 3.5.4 Linux ARM64 caveat

If upstream `llama.cpp` release `b8946` doesn't ship a pre-built `linux-arm64` binary (its CI matrix is x64-heavy historically), `scripts/fetch-llama-binaries.sh` falls back to building from source on a `ubuntu-22.04-arm64` GitHub Actions runner (the `actions/runner-images` matrix gained ARM64 in 2024). Fallback adds ~6 minutes to the desktop CI workflow but is a one-time cost per llama.cpp version bump (the resulting binary is cached as a workflow artifact + checksummed).

#### 3.5.5 Backend support on desktop — Llama only

Desktop intentionally supports **only `BackendKind.Llama`** in v2.4. Foundation / CoreML / MLX are iOS-frameworks (no Windows / Linux story). MediaPipe / LiteRT are Android-frameworks. ONNX and ML.NET have separate dedicated NuGets (§3.7 / §3.8). Asking for any other `BackendKind` from the Desktop slice throws `BackendUnavailable` with a hint pointing to the right slice ("install `DVAIBridge.OnnxRuntime` and use `BackendKind.Onnx`").

### 3.6 ONNX Runtime backend — `DVAIBridge.OnnxRuntime`

Targets `net10.0` (cross-platform via the `Microsoft.ML.OnnxRuntime` NuGet's TFM-conditional natives — works on Windows / macOS / Linux desktop AND on iOS / Android via the same package). New `BackendKind.Onnx = 7`.

#### 3.6.1 NuGet dependencies

| Package                              | Pinned version | Source                                                            | Role                                      |
|--------------------------------------|----------------|-------------------------------------------------------------------|-------------------------------------------|
| `Microsoft.ML.OnnxRuntime`           | **1.25.0** (released 2026-04-24) | https://www.nuget.org/packages/Microsoft.ML.OnnxRuntime           | Generic ONNX runtime (CPU). RIDs covered: win-x64/arm64, osx-x64/arm64, linux-x64/arm64, ios-arm64, android-arm64/x86_64. |
| `Microsoft.ML.OnnxRuntimeGenAI`      | **0.13.1** (released 2026-04-07) | https://www.nuget.org/packages/Microsoft.ML.OnnxRuntimeGenAI      | LLM-specific extensions: `Generator` API for prompt + token streaming, KV cache management, sampling, tokenizer integration (matches HuggingFace tokenizer.json). Phi-3 / Phi-3.5 / Phi-4 / Llama-3 / Mistral / Qwen all supported via the `genai_config.json` pattern. |

Both ship NuGet-friendly cross-platform native binaries — consumers don't need a separate native-library install step.

#### 3.6.2 Architecture — `OnnxNativeBridge.cs`

Implements `INativeBridge` by:

1. `StartAsync` loads the model via `OnnxRuntimeGenAI.Model.Create(modelPath)` (the GenAI loader; expects a directory with `model.onnx` + `genai_config.json` + `tokenizer.json`, the standard HF-published ONNX layout).
2. Spins up the same Kestrel host (§3.5.3) backed by an `OnnxGenAIRunner` `IInferenceEngine` impl.
3. `GenerateAsync` constructs a `Generator` with the prompt tokens, then `yield return`s decoded tokens as the generator advances. Streaming-by-default; non-streaming is a flush-at-end of the same loop.

Tokenizer / detokenizer come from OnnxRuntimeGenAI's `Tokenizer` class (no separate `tokenizer.json` parser needed in our code — it reuses the model directory's tokenizer artifact).

#### 3.6.3 Model catalog — supported formats

- **`.onnx` + `tokenizer.json` + `genai_config.json` directory layout** (HuggingFace's canonical "ONNX runtime GenAI" packaging). Reference catalog: `microsoft/Phi-3.5-mini-instruct-onnx`, `microsoft/Phi-4-mini-onnx`, `onnx-community/Llama-3.2-3B-Instruct-ONNX`, `onnx-community/*` quantized models.
- **Plain `.onnx` for embedding models** (sentence-transformers exports). Embedding mode uses the bare `OrtSession` API, not OnnxRuntimeGenAI.
- **Quantization**: int4, int8, fp16, fp32 — all transparent to the consumer (ONNX Runtime resolves internally based on the model's encoded ops).

#### 3.6.4 Cross-platform availability matrix (ONNX)

| Platform     | RID            | Status                                                                |
|--------------|----------------|-----------------------------------------------------------------------|
| Windows      | win-x64        | ✅ Full (ORT 1.25 ships native; CPU only in v2.4, GPU is Phase 4+)    |
| Windows      | win-arm64      | ✅ Full                                                                |
| macOS        | osx-x64        | ✅ Full                                                                |
| macOS        | osx-arm64      | ✅ Full (Apple Silicon CoreML EP available but Phase 4+)              |
| Linux        | linux-x64      | ✅ Full                                                                |
| Linux        | linux-arm64    | ✅ Full                                                                |
| iOS          | ios-arm64      | ✅ Full (mobile competing with `Llama` / `CoreML` — consumer choice)  |
| iOS Sim      | iossimulator-* | ✅ Full                                                                |
| Mac Catalyst | maccatalyst-*  | ✅ Full                                                                |
| Android      | android-arm64  | ✅ Full (mobile competing with `Llama` / `MediaPipe` / `LiteRT`)      |
| Android      | android-x86_64 | ✅ Full (emulator)                                                     |

ONNX is the **only backend** in the family that's truly cross-platform-uniform — both desktop and mobile consumers can pick it.

### 3.7 ML.NET backend — `DVAIBridge.MLNet`

Targets `net10.0`. New `BackendKind.MLNet = 8`. **Desktop primary**; iOS/Android best-effort with documented caveats (no GPU, large IL footprint, slower than ONNX Runtime direct).

#### 3.7.1 NuGet dependencies

| Package                          | Pinned version | Source                                                         | Role                                      |
|----------------------------------|----------------|----------------------------------------------------------------|-------------------------------------------|
| `Microsoft.ML`                   | **5.0.0** (released 2025-11-11, the .NET 10 GA companion) | https://www.nuget.org/packages/Microsoft.ML                   | MLContext, IDataView, pipeline runtime    |
| `Microsoft.ML.OnnxTransformer`   | **5.0.0**      | https://www.nuget.org/packages/Microsoft.ML.OnnxTransformer  | ONNX integration into ML.NET pipelines    |

Both are first-party Microsoft packages; both pin to the matching v5.0.0 release.

#### 3.7.2 Architecture — `MLNetNativeBridge.cs`

Wraps `MLContext` + `Microsoft.ML.OnnxTransformer.OnnxScoringEstimator` to load an ONNX model into an ML.NET pipeline, then exposes the same Kestrel `/v1/*` surface. The pipeline is single-input / single-output: input is the prompt's tokenized `int64[]` tensor, output is the next-token logits tensor; we run it in a loop with a tokenizer/sampler ourselves (since ML.NET's pipeline abstraction doesn't have a streaming-token-generator concept the way OnnxRuntimeGenAI does).

#### 3.7.3 ONNX vs ML.NET — overlap and positioning

Both backends ultimately load `.onnx` models. Honest framing for the docs:

| Question                                              | `BackendKind.Onnx` (DVAIBridge.OnnxRuntime)         | `BackendKind.MLNet` (DVAIBridge.MLNet)            |
|-------------------------------------------------------|------------------------------------------------------|---------------------------------------------------|
| What's the underlying runtime?                        | `Microsoft.ML.OnnxRuntime` direct                    | ML.NET pipeline → `OnnxScoringEstimator` → ORT    |
| Built-in LLM tooling (KV cache, sampling, tokenizer)? | Yes — `Microsoft.ML.OnnxRuntimeGenAI`               | No — implemented manually in `MLNetNativeBridge`  |
| Best for...                                            | LLM inference where ONNX is the only goal           | Apps already using ML.NET pipelines for non-LLM ML (recommendation, classification, regression) that want to add LLM as one more transform |
| Cross-platform mobile?                                 | Yes (full)                                           | Best-effort (no GPU on mobile; large IL footprint; doesn't compete with ONNX direct on perf) |
| Footprint on disk                                      | Smaller (~10 MB managed assemblies + ORT natives)    | Larger (~25 MB managed assemblies + same ORT natives transitively) |
| Recommendation                                         | **Default for new projects**                         | Use if you're already deep in ML.NET ergonomics    |

Both ship; the docs steer consumers toward `Onnx` unless they have an existing ML.NET pipeline to integrate with. See §6 Q13 for the full decision rationale.

#### 3.7.4 Cross-platform availability matrix (ML.NET)

| Platform     | Status                                                  |
|--------------|---------------------------------------------------------|
| Windows      | ✅ Full (primary target)                                 |
| macOS        | ✅ Full                                                  |
| Linux        | ✅ Full                                                  |
| Mac Catalyst | ⚠️  Best-effort (works; not perf-tuned)                 |
| iOS          | ⚠️  `BackendKind.MLNet` rejected at facade — use `Onnx`  |
| Android      | ⚠️  `BackendKind.MLNet` rejected at facade — use `Onnx`  |

### 3.8 BackendKind × platform availability matrix

The single source of truth for "which backend runs where":

| BackendKind   | iOS | Catalyst | macOS-desktop (DVAIBridge.Desktop on osx-arm64) | Android | Win-x64 | Win-arm64 | Linux-x64 | Linux-arm64 | NuGets needed                                                  |
|---------------|-----|----------|--------------------------------------------------|---------|---------|-----------|-----------|-------------|----------------------------------------------------------------|
| `Auto`        | ✅  | ✅       | ✅                                               | ✅      | ✅      | ✅        | ✅        | ✅          | Just the facade; selects the platform default                  |
| `Llama`       | ✅  | ✅       | ✅                                               | ✅      | ✅      | ✅        | ✅        | ✅          | iOS/Android/Catalyst slice OR `DVAIBridge.Desktop`             |
| `Foundation`  | ✅  | ✅       | ❌                                               | ❌      | ❌      | ❌        | ❌        | ❌          | `DVAIBridge.iOS` (iOS 18+ for the Apple Foundation Models API) |
| `CoreML`      | ✅  | ✅       | ❌                                               | ❌      | ❌      | ❌        | ❌        | ❌          | `DVAIBridge.iOS`                                                |
| `MLX`         | ✅  | ✅       | ❌                                               | ❌      | ❌      | ❌        | ❌        | ❌          | `DVAIBridge.iOS` (Apple Silicon only)                          |
| `MediaPipe`   | ❌  | ❌       | ❌                                               | ✅      | ❌      | ❌        | ❌        | ❌          | `DVAIBridge.Android`                                            |
| `LiteRT`      | ❌  | ❌       | ❌                                               | ✅      | ❌      | ❌        | ❌        | ❌          | `DVAIBridge.Android`                                            |
| `Onnx`        | ✅  | ✅       | ✅                                               | ✅      | ✅      | ✅        | ✅        | ✅          | `DVAIBridge.OnnxRuntime`                                        |
| `MLNet`       | ❌  | ⚠️       | ✅                                               | ❌      | ✅      | ✅        | ✅        | ✅          | `DVAIBridge.MLNet`                                              |

`PlatformBridgeFactory.Create()` consults this matrix at runtime; when a consumer requests `BackendKind.X` on platform Y, the factory picks the right `INativeBridge` implementation (e.g. `OnnxNativeBridge` if `BackendKind.Onnx` and `DVAIBridge.OnnxRuntime` is loaded; `IOSNativeBridge` if iOS + `BackendKind.Llama`; `DesktopNativeBridge` if Windows + `BackendKind.Llama`). The "is this slice loaded?" check uses `Type.GetType("DVAIBridge.OnnxRuntime.OnnxNativeBridge, DVAIBridge.OnnxRuntime") is not null` so a consumer who hasn't installed the `DVAIBridge.OnnxRuntime` NuGet gets a clean `BackendUnavailable("install DVAIBridge.OnnxRuntime")` error rather than a `TypeLoadException`.

### 3.9 Cross-platform validation

The facade pre-validates the BackendKind against the runtime platform:

```csharp
public sealed class DVAIBridge
{
    private static readonly HashSet<BackendKind> IosOnly = new()
    {
        BackendKind.Foundation, BackendKind.CoreML, BackendKind.MLX,
    };
    private static readonly HashSet<BackendKind> AndroidOnly = new()
    {
        BackendKind.MediaPipe, BackendKind.LiteRT,
    };

    public async Task<BoundServer> StartAsync(StartOptions opts, CancellationToken ct = default)
    {
        if (OperatingSystem.IsIOS() && AndroidOnly.Contains(opts.Backend))
            throw DVAIBridgeException.BackendUnavailable(opts.Backend, $"{opts.Backend} is Android-only");
        if (OperatingSystem.IsAndroid() && IosOnly.Contains(opts.Backend))
            throw DVAIBridgeException.BackendUnavailable(opts.Backend, $"{opts.Backend} is iOS-only");
        if (!OperatingSystem.IsIOS() && !OperatingSystem.IsAndroid())
            throw DVAIBridgeException.BackendUnavailable(opts.Backend,
                "DVAIBridge native bindings only ship for iOS and Android in v2.4.");
        return await _bridge.StartAsync(opts, ct).ConfigureAwait(false);
    }
}
```

The native bindings still do their own check (e.g. `IOSNativeBridge` rejects MediaPipe before even reaching the Obj-C layer); the duplicate is intentional defense-in-depth.

### 3.10 IAsyncEnumerable<ProgressEvent> reactive surface

The facade exposes:

```csharp
public IAsyncEnumerable<ProgressEvent> ProgressEvents { get; }
```

backed by an internal `ProgressBroadcaster` (a fan-out wrapper around per-subscriber `BoundedChannel<ProgressEvent>` instances; `BoundedChannelFullMode.DropOldest` so a slow consumer never blocks the writer or other consumers). Each consumer who calls `await foreach` gets a fresh dedicated channel; the writer (the native progress callback) emits to **all** of them. Cancellation propagates: `WithCancellation(ct)` cancels the loop and removes the consumer's channel from the broadcaster's set without affecting other consumers.

> **v2.4.0-rc1 implementation note**: rev 1 of this spec proposed a single bare `Channel<T>.CreateUnbounded` shared across all subscribers, but `Channel<T>` fans out by **competition** (each event goes to exactly one reader). That's wrong for a progress broadcaster — every UI subscriber wants every event. The implementation in `ProgressBroadcaster.cs` (committed in v2.4.0-rc1) fixes this with the per-subscriber-channel pattern. Spec rev 2 reflects the as-built design.

```csharp
public sealed class DVAIBridge
{
    private readonly Channel<ProgressEvent> _progress = Channel.CreateUnbounded<ProgressEvent>(
        new UnboundedChannelOptions { SingleReader = false, SingleWriter = true });

    // Writer side — fed by a subscription opened in the constructor that calls
    // _bridge.OnProgress(ev => _progress.Writer.TryWrite(ev)).
    // Reader side — exposed publicly:

    public async IAsyncEnumerable<ProgressEvent> GetProgressEventsAsync(
        [EnumeratorCancellation] CancellationToken ct = default)
    {
        await foreach (var ev in _progress.Reader.ReadAllAsync(ct).ConfigureAwait(false))
            yield return ev;
    }

    // Convenience — simpler call site for consumers who don't want to thread a CT.
    public IAsyncEnumerable<ProgressEvent> ProgressEvents => GetProgressEventsAsync();

    public async ValueTask<DVAIBridgeState> GetStateAsync(CancellationToken ct = default)
    {
        var status = await _bridge.GetStatusAsync(ct).ConfigureAwait(false);
        return new DVAIBridgeState(
            IsReady: status.Running,
            BaseUrl: status.BaseUrl,
            Port: status.Port,
            Backend: status.Backend,
            ModelId: status.ModelId);
    }
}
```

This follows the modern .NET idiom — `Channel<T>` + `IAsyncEnumerable<T>` is the recommended pattern for push-style event streams in .NET 8+ ([dotnet/runtime issue #75833](https://github.com/dotnet/runtime/issues/75833) tracks the official guidance). It's also what `Microsoft.AspNetCore.SignalR` uses internally for client-side push streams, and what `Microsoft.Extensions.AI` (.NET 10) uses for the `IChatClient.GetStreamingResponseAsync` API. Consumers who prefer Rx.NET can call `.ToObservable()` from `System.Linq.Async` (`Reactive.Linq.AsyncEnumerable`).

### 3.11 Threading model

- **Facade**: `Task<T>` async/await throughout. The `Channel<T>` writer is single-writer (one subscription per `INativeBridge` instance), which lets us use the high-throughput `UnboundedChannelOptions { SingleWriter = true }` config.
- **iOS bindings**: each `[Async]`-bound method opens a `Task { ... }` on the Swift side and calls the C# completion handler off the Combine main-actor queue. The bound C# method materializes back as `Task<T>` via the binding generator's `[Async]` synthesis.
- **Android bindings**: the metadata transform rewrites Kotlin's `suspend fun(continuation)` to a `Task<T>`-returning C# method using the binding generator's coroutine adapter (.NET 10 Android workload includes this since .NET 8; the Kotlin shim is a fallback only if the auto-conversion fails for `Flow<ProgressEvent>`).

### 3.12 Test seam

`DVAIBridge.Tests` (xUnit) imports `[InternalsVisibleTo]` from the facade and constructs `new DVAIBridge(IFakeNativeBridge)` for unit tests. Tests cover:

- `StartAsync` rejects iOS-only backend on Android (synthetic `OperatingSystem` shim) and vice-versa.
- `StartAsync` rejects all backends on Windows (synthetic shim).
- `GetStateAsync` returns the right snapshot for a fake bridge.
- `ProgressEvents` await-foreaches a fed sequence in order.
- Error mapping: native-thrown `BackendUnavailableError` → `DVAIBridgeException(Kind: BackendUnavailable)` with the right Reason.
- Cancellation: `ProgressEvents.WithCancellation(ct)` exits cleanly when `ct` fires.

## 4. Distribution

### 4.1 NuGet.org — public registry

The dvai-bridge family publishes JS to GitHub Packages npm and Maven artifacts to GitHub Packages Maven; Phase 3F broke that pattern by going to pub.dev (the only realistic public registry for Flutter consumers, since pub.dev has no first-class private feed). 3G has the same forcing function: **NuGet.org is the default registry for every .NET tutorial, every IDE one-click "Add Package", every `dotnet add package` invocation in the wild.** GitHub Packages NuGet is supported but requires consumers to:

1. Add a `nuget.config` file with the GitHub Packages source URL.
2. Configure a personal access token with `read:packages` scope.
3. Tell their CI to thread the token through to `dotnet restore`.

Step 3 in particular is a lift for new consumers — every Visual Studio template, every dev-loop "open in VS, hit F5" flow, expects NuGet.org to Just Work. We accept the asymmetry and **publish to NuGet.org as public packages**.

Asymmetry table (call out in `docs/migration/v2.3-to-v2.4.md`):

| Family member               | Distribution                                  | Public/Private |
|-----------------------------|-----------------------------------------------|----------------|
| `@dvai-bridge/capacitor`    | npm (GitHub Packages)                         | private        |
| `@dvai-bridge/ios`          | SwiftPM (GitHub repo) + CocoaPods (Trunk)     | public (CocoaPods) / private (GH SPM auth optional) |
| `@dvai-bridge/android`      | Maven (GitHub Packages)                       | private        |
| `@dvai-bridge/react-native` | npm (GitHub Packages)                         | private        |
| `dvai_bridge` (Flutter)     | pub.dev                                       | public         |
| `DVAIBridge` (.NET facade)         | **NuGet.org**                          | **public**     |
| `DVAIBridge.iOS` (.NET)            | **NuGet.org**                          | **public**     |
| `DVAIBridge.Android` (.NET)        | **NuGet.org**                          | **public**     |
| `DVAIBridge.Desktop` (.NET)        | **NuGet.org**                          | **public**     |
| `DVAIBridge.OnnxRuntime` (.NET)    | **NuGet.org**                          | **public**     |
| `DVAIBridge.MLNet` (.NET)          | **NuGet.org**                          | **public**     |

The .NET family is the third + fourth + fifth + sixth + seventh + eighth public family members (joining the iOS CocoaPod and the Flutter pub.dev package; one NuGet ID per slice). The packages themselves are OSS-friendly; the underlying iOS SwiftPM dep + Android Maven dep are still gated. The iOS binding's xcframework is bundled inside the NuGet (so consumers don't need a separate SwiftPM auth), and the Desktop slice's `llama.cpp` binaries are bundled (so consumers don't need a CMake / Visual Studio Build Tools / make toolchain). The Android binding still requires the consumer's app to add the GitHub Packages Maven repo (because the Android binding consumes the AAR at consumer-build time, not bundles it). Document clearly in the README and consumer guide so .NET MAUI consumers don't expect a one-line `dotnet add package` to be sufficient on Android — they still need a GH PAT for the Maven AAR. ONNX and ML.NET have no consumer-side credential requirements (their underlying NuGets are public Microsoft packages). See §4.3.

### 4.2 NuGet package contents

**Six packages**, all sharing the version `2.4.0`:

| Package                  | TFM(s)                                                        | Contents                                                                                                                                                     |
|--------------------------|---------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `DVAIBridge`             | `net10.0`                                                     | facade DLL + xmldoc; declares TFM-conditional + RID-conditional `<Dependency>` on the platform slices (see below)                                           |
| `DVAIBridge.iOS`         | `net10.0-ios18.0;net10.0-maccatalyst18.0` (multi-target)      | iOS + Catalyst binding DLL + bundled `DVAIBridgeNetBridge.xcframework` (~3 MB; ios + ios-sim + maccatalyst slices)                                          |
| `DVAIBridge.Android`     | `net10.0-android36.0`                                         | Android binding DLL + transform XML + binding metadata (no AAR — pulled at consumer-build time)                                                              |
| `DVAIBridge.Desktop`     | `net10.0` + `<RuntimeIdentifiers>win-x64;win-arm64;osx-x64;osx-arm64;linux-x64;linux-arm64</RuntimeIdentifiers>` | desktop slice DLL + `runtimes/<rid>/native/llama.{dll,dylib,so}` per RID (~25 MB total uncompressed across all 6 RIDs; ~6 MB per RID)                       |
| `DVAIBridge.OnnxRuntime` | `net10.0`                                                     | ONNX backend DLL + transitively pulls `Microsoft.ML.OnnxRuntime 1.25.0` + `Microsoft.ML.OnnxRuntimeGenAI 0.13.1` (which carry their own RID-keyed natives)  |
| `DVAIBridge.MLNet`       | `net10.0`                                                     | ML.NET backend DLL + transitively pulls `Microsoft.ML 5.0.0` + `Microsoft.ML.OnnxTransformer 5.0.0`                                                          |

The facade's `.nuspec` declares TFM-conditional dependencies for the platform slices that get auto-pulled, and **does not** declare deps on the optional `DVAIBridge.OnnxRuntime` / `DVAIBridge.MLNet` (consumers add those explicitly when they want those backends):

```xml
<dependencies>
  <group targetFramework="net10.0">
    <!-- Desktop slice: only pulled if the consumer's RID is in our supported set.
         RID-conditional inclusion is via runtime.json inside the facade nupkg. -->
    <dependency id="DVAIBridge.Desktop" version="[2.4.0]" include="all" exclude="none" />
  </group>
  <group targetFramework="net10.0-ios18.0">
    <dependency id="DVAIBridge.iOS" version="[2.4.0]" />
  </group>
  <group targetFramework="net10.0-maccatalyst18.0">
    <dependency id="DVAIBridge.iOS" version="[2.4.0]" />
  </group>
  <group targetFramework="net10.0-android36.0">
    <dependency id="DVAIBridge.Android" version="[2.4.0]" />
  </group>
</dependencies>
```

> **Trade-off on auto-pulling Desktop**: alternative is to require consumers to `dotnet add package DVAIBridge.Desktop` explicitly (the same way ONNX / MLNet are opt-in). We chose auto-pull for `DVAIBridge.Desktop` because Llama is the **default** backend on desktop in the platform-availability matrix (§3.8) — a Windows / Linux / macOS desktop consumer expecting `BackendKind.Auto` to work should not have to install a second NuGet for the obvious case. ONNX / MLNet stay opt-in because they're alternative backends, not platform requirements.

So `dotnet add package DVAIBridge` from a multi-TFM MAUI csproj automatically pulls the iOS slice on iOS + Catalyst targets, the Android slice on Android targets, and the Desktop slice on plain `net10.0` (with RID-keyed natives). WinUI / Avalonia / MAUI-desktop / console / server consumers get a working Llama backend out of the box. Adding `dotnet add package DVAIBridge.OnnxRuntime` enables the `BackendKind.Onnx` route; adding `DVAIBridge.MLNet` enables `BackendKind.MLNet`.

### 4.3 Consumer integration

```bash
dotnet add package DVAIBridge --version 2.4.0
```

For an iOS-targeting MAUI app, no further config is required — the xcframework is bundled in the NuGet.

For an Android-targeting MAUI app, the consumer's csproj needs the GitHub Packages Maven repo entry (because the Android binding pulls the AAR at consumer-build time, not bundles it):

```xml
<ItemGroup Condition="$(TargetFramework.Contains('android'))">
  <AndroidMavenLibrary Include="co.deepvoiceai:dvai-bridge"
                       Version="2.4.0"
                       Repository="https://maven.pkg.github.com/deep-voice-ai/dvai-bridge" />
</ItemGroup>
```

Plus a `~/.nuget/NuGet.config` or repo-local `nuget.config` with the credentials:

```xml
<configuration>
  <packageSourceCredentials>
    <github>
      <add key="Username" value="%GITHUB_USER%" />
      <add key="ClearTextPassword" value="%GITHUB_TOKEN%" />
    </github>
  </packageSourceCredentials>
</configuration>
```

Then in C#:

```csharp
using DVAIBridge;
```

We document this asymmetry vs. iOS prominently in `docs/guide/dotnet-sdk.md`.

## 5. Versioning

3G ships under the `2.x.y` line. Phase 3F was tagged at `v2.3.0`; **Phase 3G is `v2.4.0`** (minor bump — additive). The Phase 3D Android umbrella AAR also bumps to 2.4.0 for build-graph consistency (no source changes; just a republish to align the `dvaiBridgeVersion` Gradle property). The Phase 3C iOS umbrella stays at 2.3 (no source changes; the Swift wrapper depends on `DVAIBridge`'s public API which hasn't shifted, and the Catalyst slice already builds against 2.3 unchanged). The Flutter pub.dev package stays at 2.3 (no source changes).

All six .NET assemblies + NuGet packages share version `2.4.0`. CPM ([Central Package Management](https://learn.microsoft.com/en-us/nuget/consume-packages/central-package-management)) via `Directory.Packages.props` keeps every dep version pinned at one place.

Once 3H (docs/launch) follows it stays at 2.4 (editorial only).

**Effort estimate**: rev 1 of this spec scoped ~3 days for iOS + Android only (delivered as v2.4.0-rc1 on 2026-04-27). Rev 2's scope expansion adds:

| Slice / task                                         | Effort        |
|------------------------------------------------------|---------------|
| Mac Catalyst slice (multi-target TFM + xcframework re-export) | 0.5 day  |
| Desktop slice — scaffold + RID-keyed natives + P/Invoke + Kestrel host | 5 days |
| ONNX Runtime backend                                 | 2 days        |
| ML.NET backend                                       | 2 days        |
| Updated tests across all slices                      | 1.5 days      |
| Updated docs (`dotnet-sdk.md` + per-backend sections + migration v2.3→v2.4 update) | 1 day |
| **Total rev 2 expansion**                            | **~12 days**  |
| Combined (rev 1 + rev 2)                             | **~15 days**  |

## 6. Open questions (decided)

Per the project's "no deferrals" rule, every open question is resolved here:

1. **Package structure: single unified `DVAIBridge` NuGet vs split iOS/Android/facade?** → **Split into three packages with the facade declaring TFM-conditional deps on the slices.** This is the canonical .NET MAUI binding pattern (see [`Plugin.Maui.Audio`](https://github.com/jfversluis/Plugin.Maui.Audio), [`CommunityToolkit.Maui`](https://github.com/CommunityToolkit/Maui)). Reasons:
   - **NuGet content separation** — iOS bindings ship with a 3 MB xcframework that Windows / Linux / macOS consumers never need. Bundling them into a single NuGet means a 3 MB "Hello World" Avalonia desktop app for no reason.
   - **TFM-conditional ItemGroups** — the binding csproj's `<NativeReference>` (iOS) and `<AndroidLibrary>` (Android) items only make sense under their respective platform TFMs; mixing them into a single multi-TFM package creates per-TFM conditional restore graphs that confuse `dotnet restore`.
   - **Version-locked transitive deps** — the facade's `[2.4.0]` exact-version constraint on the slices gives consumers a single coherent version axis (they only ever see "DVAIBridge 2.4.0"), so the split-package overhead is invisible.

   Trade-off vs. unified single-package (Flutter / RN approach): three csprojs to maintain, three NuGet IDs to publish. Acceptable — the .NET ecosystem expects this shape.

2. **Distribution: GitHub Packages NuGet vs NuGet.org?** → **NuGet.org (public).** See §4.1. .NET tooling deeply assumes NuGet.org availability; GitHub Packages NuGet adds friction at install time that's unjustified for this package family (the underlying SDKs are already private; the .NET facade itself is OSS-friendly). Family asymmetry documented in the migration guide.

3. **Streaming pattern: `IAsyncEnumerable<ProgressEvent>` vs `IObservable<ProgressEvent>` (Rx.NET)?** → **`IAsyncEnumerable<T>` (with a Channel<T> writer behind the scenes).** Modern .NET (.NET 6+) treats `IAsyncEnumerable<T>` as the canonical asynchronous stream. Reasons:
   - **Language integration**: `await foreach` is C# 8+ syntax; no third-party dependency required.
   - **Microsoft alignment**: `Microsoft.Extensions.AI`, `Microsoft.SemanticKernel`, ASP.NET Core SignalR, `System.IO.Pipelines.PipeReader` all use `IAsyncEnumerable<T>` as their public stream surface.
   - **Cancellation story**: `WithCancellation(ct)` is built-in; Rx requires `IObservable<T>.ToTask(ct)` or wrappers.
   - **Less mental overhead**: no hot-vs-cold observable distinction, no `Subject<T>` / `BehaviorSubject<T>` choice, no `Subscribe`-returning-`IDisposable` lifetime-management.
   - **Rx interop**: `System.Linq.Async`'s `IAsyncEnumerable<T>.ToObservable()` is one method call; consumers who want Rx aren't blocked.

   Rejected: `IObservable<T>` would require either a `System.Reactive` dep (40 KB extra; transitively pulled in for every consumer) or a hand-rolled `IObservable<T>` impl (more code, no free Rx operators). Either way, Rx in 2026 is "still-used-but-no-longer-canonical" .NET; new public APIs default to `IAsyncEnumerable<T>` per the same logic that flipped Java/Kotlin's RxJava → Coroutines/Flow migration.

4. **Min .NET version: 8 (LTS), 9 (latest), 10 (latest LTS), or multi-target?** → **Single-target `net10.0` (with `net10.0-ios18.0` / `net10.0-android36.0` slices).** .NET 10 is LTS through November 2028 (released November 11, 2025) — the same support window as .NET 8 (which goes EOL November 2026, ~7 months after this package ships). Multi-targeting `net8.0;net9.0;net10.0` would force us to give up `net10.0`-only language features (collection expressions, `field` keyword, params collections, ref-struct interfaces) and complicate the binding-csproj TFM matrix for marginal upgrade-path benefit. .NET 8 consumers can install `DVAIBridge 2.3.x`-line releases (none yet exist; 2.4 is the first .NET-supporting release); a future .NET 8-targeting backport can ship as `2.4.x-net8` if real-world demand materializes.

   Note: per Microsoft's .NET 10 docs, `net10.0` consumers can transparently consume libraries built for `net8.0` / `net9.0` (forward compatibility), so a `net10.0`-targeted package is consumable from a `net8.0` / `net9.0` app too — **but only on platforms where the platform-version TFM matches**. Since the binding TFMs are platform-versioned (`-ios18.0`, `-android36.0`), a `net8.0-ios17.2` consumer cannot consume `DVAIBridge.iOS` 2.4.0 directly. Acceptable: we publicly require .NET 10 in v2.4 and document the path forward for older-.NET consumers in `docs/migration/v2.3-to-v2.4.md`.

5. **Min iOS / Android target?** → **iOS 15.1 / Android API 24** (matches the underlying SDKs; the binding TFMs `net10.0-ios18.0` / `net10.0-android36.0` are *bindings* TPVs — what API levels the binding code can compile against — not runtime floors). Set `<SupportedOSPlatformVersion>15.1</SupportedOSPlatformVersion>` in `DVAIBridge.iOS.csproj` and `<SupportedOSPlatformVersion>24</SupportedOSPlatformVersion>` in `DVAIBridge.Android.csproj`.

6. **Bindings approach for iOS Swift: bind the framework directly vs. wrap in @objc Swift?** → **Wrap in `@objc` Swift then bind that.** Microsoft's Native Library Interop guide explicitly recommends this for Swift libraries with non-`@objc`-friendly surface (actors, generics, protocols-with-associated-types — all of which `DVAIBridge.swift` uses). The wrapper is ~150 LOC and we control it; the alternative (Sharpie-generate ApiDefinition.cs against the existing umbrella's `-Swift.h`) leaks Swift-internals into the C# surface and breaks every time the underlying SDK shuffles its Swift-private types.

7. **NativeAOT compatibility?** → **Not in v2.4.** Both the iOS and Android binding generators rely on dynamic Obj-C / JNI marshalling that produces NativeAOT-incompatible IL (reflection on bound types, dynamic-method-table lookups). The facade is AOT-clean but the binding slices are not. Document; consumers can still ship NativeAOT iOS apps with `DVAIBridge` if they're willing to accept the trim warnings (dotnet/macios issue #19811 tracks the canonical fix). Phase 4 candidate: re-spec the bindings with explicit AOT-friendly attribute annotations.

8. **WinUI 3 / Avalonia / desktop consumers?** → ~~**Compile-clean, runtime-fail.**~~ **(Rev 2 — superseded by Q11.)** Desktop is now first-class via `DVAIBridge.Desktop` (Llama via P/Invoke + Kestrel) on `win-x64` / `win-arm64` / `osx-x64` / `osx-arm64` / `linux-x64` / `linux-arm64`. See §3.5. Rev 1's "compile-clean, runtime-fail" approach was rejected after the user's review of the v2.4.0-rc1 build: 5 of 6 facade test failures were the `UnsupportedPlatformBridge` fall-through, and "first-class .NET LLM SDK that doesn't work on Windows" is a non-starter for the v2.4 launch.

9. **Swift wrapper packaging: bundled xcframework vs. separate SwiftPM dep on the consumer side?** → **Bundled xcframework inside `DVAIBridge.iOS.nupkg`.** Consumers should not have to set up SwiftPM credentials to use a NuGet package. CI (`build-xcframework.sh` in `native/`) builds the wrapper xcframework on macos-latest, embeds it in the NuGet via the `<NativeReference>` item, and ships. The wrapper's xcframework includes both device + simulator slices (~3 MB total). We re-publish whenever the underlying SDK ships a major update.

10. **Android shim: required or optional?** → **Optional, default-not-needed.** The Phase 3D AAR's `co.deepvoiceai.bridge.DVAIBridge` is a Kotlin `object` with `suspend fun` methods + `Flow<ProgressEvent>`. The .NET 10 Android workload's binding generator handles `suspend fun` natively (via `kotlinx.coroutines.android`'s continuation adapters that the generator special-cases). For `Flow<ProgressEvent>`, the generator emits a clunky `IFlow` C# wrapper; if that wrapper proves unergonomic during Task 4, we add `DVAIBridgeAndroidShim.kt` with a callback-based `subscribe(listener)` method and bind that instead. Default: no shim; revisit empirically.

11. **Cross-family scope of `BackendKind.Onnx` / `BackendKind.MLNet` — .NET-only or also iOS / Android / RN / Flutter?** → **.NET-only (Option Y).** The user's framing was explicit: "those were specific to dotnet" — meaning ONNX Runtime and ML.NET are first-party Microsoft .NET stacks that don't exist as primary SDKs in the Swift / Kotlin / JS / Dart ecosystems. While ONNX Runtime does ship CocoaPods / Maven / npm artifacts, exposing them through the existing iOS / Android / RN / Flutter wrappers would (a) double the maintenance surface for backends that .NET consumers asked for and other consumers haven't, (b) require duplicating the Kestrel-style HTTP host pattern across Swift / Kotlin / TS / Dart, and (c) widen the cross-wrapper `BackendKind` union from 7 to 9 cases on every wrapper for marginal benefit.

    Rejected — Option X (cross-family ONNX / MLNet): would force every wrapper to either implement an Onnx backend or reject the case at start-time with `BackendUnavailable`. Either way is more code with no consumer pull.

    Net result: the .NET wrapper is the only family member with 9 `BackendKind` cases; iOS / Android / RN / Flutter stay at 7. The asymmetry is documented in `docs/guide/dotnet-sdk.md` ("Why does .NET have ONNX and ML.NET when other wrappers don't?"). Phase 4+ revisits if real-world cross-wrapper demand materializes.

12. **Mac Catalyst — separate `DVAIBridge.MacCatalyst` NuGet or multi-target TFM in `DVAIBridge.iOS.csproj`?** → **Multi-target TFM in `DVAIBridge.iOS.csproj`** (`<TargetFrameworks>net10.0-ios18.0;net10.0-maccatalyst18.0</TargetFrameworks>`). Reasons:

    - **Free reuse**: the underlying Phase 3C SwiftPM package already declares `.macCatalyst(.v15_1)` as a supported platform (verified in `packages/dvai-bridge-ios/Package.swift`), the `@objc` Swift wrapper compiles against Catalyst with zero source changes, and `xcodebuild -create-xcframework` happily emits a Catalyst slice alongside the iOS device + simulator slices. Same xcframework, same `IOSNativeBridge.cs` implementation; only the TFM declaration changes.
    - **One NuGet ID, fewer publishing steps**: a separate `DVAIBridge.MacCatalyst` would mean a 4th platform NuGet, a 4th nuspec, a 4th `dotnet pack` invocation, a 4th NuGet.org listing for consumers to navigate. The multi-target approach gives consumers one `DVAIBridge.iOS` NuGet that resolves correctly under both `net10.0-ios18.0` and `net10.0-maccatalyst18.0` MAUI csproj targets.
    - **Naming cleanliness**: `DVAIBridge.iOS` containing Catalyst slices is mildly misleading (Catalyst isn't iOS), but every existing Microsoft binding NuGet that targets both (e.g. `Plugin.Maui.MediaElement`) follows the same pattern. The package description explicitly mentions "iOS + Mac Catalyst" so consumers find it.

    Rejected — separate `DVAIBridge.MacCatalyst` NuGet: more publishing surface for no consumer benefit. Could revisit in Phase 4+ if the iOS and Catalyst code paths ever diverge (they don't in v2.4 — they're literally the same `IOSNativeBridge.cs` instance).

13. **ONNX vs ML.NET positioning — overlap honest? differentiation framing?** → **Honest overlap; ONNX is the recommended default; ML.NET is the "you're already in ML.NET" backend.** Both run `.onnx` models; both ultimately call into `Microsoft.ML.OnnxRuntime`'s native binaries. The differentiation:

    - `BackendKind.Onnx` (`DVAIBridge.OnnxRuntime`): direct ORT + OnnxRuntimeGenAI. Built-in LLM tooling (KV cache, sampling, tokenizer integration). Smaller managed assembly footprint. **Default for new projects** that just want LLM inference.
    - `BackendKind.MLNet` (`DVAIBridge.MLNet`): ML.NET pipeline → `OnnxScoringEstimator` → ORT. No built-in LLM tooling — we implement it manually. Larger managed assembly footprint (ML.NET's `MLContext` carries IDataView, classical-ML estimators, AutoML hooks). **Best for apps already using ML.NET** for non-LLM tasks (recommendation, classification, regression) that want to add an LLM transform to their existing pipeline.

    The user explicitly asked for both ("those were specific to dotnet"), so we ship both rather than picking one. The docs steer consumers toward `Onnx` unless they have an existing ML.NET pipeline; the trade-off table in §3.7.3 makes this explicit. We don't expect heavy `MLNet` adoption — it's there to satisfy the "ML.NET shop" use case, not to compete head-on with `Onnx` for greenfield consumers.

    Rejected — drop `MLNet` and ship `Onnx` only: the user's request was explicit; second-guessing it now would surface as a missing-feature complaint within a release cycle. Also rejected — merge `MLNet` into `Onnx` as a flag: the dependency graphs are different (MLNet pulls ~25 MB of ML.NET infrastructure ONNX consumers don't need); separate NuGets keep the lean ONNX path lean.

## 7. References

- Phase 3C iOS SDK spec: [docs/superpowers/specs/2026-04-26-phase3c-ios-native-sdk-design.md](2026-04-26-phase3c-ios-native-sdk-design.md)
- Phase 3D Android SDK spec: [docs/superpowers/specs/2026-04-27-phase3d-android-native-sdk-design.md](2026-04-27-phase3d-android-native-sdk-design.md)
- Phase 3E React Native spec: [docs/superpowers/specs/2026-04-27-phase3e-react-native-module-design.md](2026-04-27-phase3e-react-native-module-design.md)
- Phase 3F Flutter spec: [docs/superpowers/specs/2026-04-27-phase3f-flutter-package-design.md](2026-04-27-phase3f-flutter-package-design.md)
- Phase 3 foundation spec: [docs/superpowers/specs/2026-04-26-phase3-foundation-design.md](2026-04-26-phase3-foundation-design.md)
- .NET 10 release announcement: https://devblogs.microsoft.com/dotnet/announcing-dotnet-10/
- .NET support policy: https://dotnet.microsoft.com/en-us/platform/support/policy/dotnet-core
- Target frameworks reference (TFM table including `net10.0-ios`, `net10.0-android`): https://learn.microsoft.com/en-us/dotnet/standard/frameworks
- .NET 10 default TPVs (Android 36.0, iOS 18.7): https://learn.microsoft.com/en-us/dotnet/standard/frameworks#os-version-in-tfms
- .NET MAUI 10 supported platforms: https://learn.microsoft.com/en-us/dotnet/maui/supported-platforms?view=net-maui-10.0
- Native Library Interop guide (Swift @objc wrapper pattern): https://devblogs.microsoft.com/dotnet/native-library-interop-dotnet-maui/
- Native Library Interop docs: https://learn.microsoft.com/en-us/dotnet/communitytoolkit/maui/native-library-interop/get-started
- Xamarin.iOS binding migration to .NET MAUI: https://learn.microsoft.com/en-us/dotnet/maui/migration/ios-binding-projects
- Xamarin.Android binding migration to .NET MAUI: https://learn.microsoft.com/en-us/dotnet/maui/migration/android-binding-projects
- IAsyncEnumerable vs IObservable for event streams: https://dev.to/asik/comparing-iasyncenumerable-and-iobservable-for-event-streams-5g96
- System.Threading.Channels guidance (push-style streams): https://learn.microsoft.com/en-us/dotnet/core/extensions/channels
- NuGet Central Package Management: https://learn.microsoft.com/en-us/nuget/consume-packages/central-package-management
- NativeAOT for iOS state in .NET 10: https://github.com/dotnet/macios/blob/main/docs/nativeaot.md
- GitHub Packages NuGet registry docs: https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-nuget-registry
- Existing iOS DVAIBridge SDK: `packages/dvai-bridge-ios/`
- Existing Android DVAIBridge SDK: `packages/dvai-bridge-android/`
- Existing Flutter dvai_bridge plugin: `packages/dvai-bridge-flutter/`

### Rev 2 additions — desktop + ONNX + ML.NET

- llama.cpp upstream: https://github.com/ggerganov/llama.cpp (release `b8946`, 2026-04-27)
- llama.cpp release page (RID-keyed prebuilts): https://github.com/ggerganov/llama.cpp/releases/tag/b8946
- llama.cpp public C API reference: https://github.com/ggerganov/llama.cpp/blob/master/include/llama.h
- `Microsoft.ML.OnnxRuntime` 1.25.0 (NuGet): https://www.nuget.org/packages/Microsoft.ML.OnnxRuntime
- `Microsoft.ML.OnnxRuntimeGenAI` 0.13.1 (NuGet): https://www.nuget.org/packages/Microsoft.ML.OnnxRuntimeGenAI
- ONNX Runtime GenAI docs (Generator API, model packaging): https://onnxruntime.ai/docs/genai/
- HuggingFace ONNX-GenAI model catalog (Phi-3.5-mini, Phi-4, Llama-3.2): https://huggingface.co/microsoft/Phi-3.5-mini-instruct-onnx
- `Microsoft.ML` 5.0.0 (NuGet): https://www.nuget.org/packages/Microsoft.ML
- `Microsoft.ML.OnnxTransformer` 5.0.0 (NuGet): https://www.nuget.org/packages/Microsoft.ML.OnnxTransformer
- ML.NET docs: https://learn.microsoft.com/en-us/dotnet/machine-learning/
- ASP.NET Core minimal API host pattern (Kestrel inside library): https://learn.microsoft.com/en-us/aspnet/core/fundamentals/minimal-apis/overview
- .NET runtime-identifier (RID) catalog: https://learn.microsoft.com/en-us/dotnet/core/rid-catalog
- `<RuntimeIdentifiers>` and `runtimes/<rid>/native/` packing convention: https://learn.microsoft.com/en-us/nuget/create-packages/native-files-in-net-packages
- `NativeLibrary.SetDllImportResolver` for explicit native lookup: https://learn.microsoft.com/en-us/dotnet/standard/native-interop/native-library-loading
- Mac Catalyst TFM in .NET 10: https://learn.microsoft.com/en-us/dotnet/standard/frameworks#net-tfms-with-os-versions
