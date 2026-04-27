# Phase 3G — .NET NuGet Packages (`DVAIBridge.Net` family)

**Status:** Draft — awaiting review
**Date:** 2026-04-27
**Scope:** A unified .NET NuGet package family that wraps the Phase 3C iOS Native SDK + Phase 3D Android Native SDK behind a single managed C# API. Drop-in for any .NET 10 (LTS, current) consumer — .NET MAUI, Avalonia, Xamarin (legacy), WinUI 3 — that needs a local LLM with an OpenAI-compatible HTTP endpoint. Zero managed-side inference engine, zero P/Invoke calls into LLM internals; binding-layer P/Invoke only into the existing Swift / Kotlin SDKs via Microsoft's iOS bindings (`@objc` ApiDefinition) and Android bindings (Java/Kotlin → C# generator) tooling.

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

1. Stand up `packages/dvai-bridge-dotnet/` — three NuGet packages (`DVAIBridge`, `DVAIBridge.iOS`, `DVAIBridge.Android`) in a single solution, published from a single tag. Single `using DVAIBridge;` import for consumers regardless of platform; the iOS/Android slices are pulled in transitively by TFM-conditional `<PackageReference>` entries.
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
4. Cross-platform `BackendKind` is the **union** of iOS and Android cases:
   ```csharp
   public enum BackendKind {
       Auto,
       Llama,
       Foundation,  // iOS-only
       CoreML,      // iOS-only
       MLX,         // iOS-only
       MediaPipe,   // Android-only
       LiteRT,      // Android-only
   }
   ```
   The facade pre-validates against the runtime platform (`OperatingSystem.IsIOS()` / `IsAndroid()`); native bindings are still authoritative and throw `DVAIBridgeException(Kind: BackendUnavailable)` if a consumer somehow bypasses the facade. On Windows / Linux / macOS / Browser TFMs (WinUI 3, Avalonia desktop, Blazor) every `Start*` call throws `DVAIBridgeException(Kind: BackendUnavailable, Reason: "no DVAIBridge native binding for this platform")` immediately.
5. Reactive state surface: `IAsyncEnumerable<ProgressEvent> ProgressEvents` + a `ValueTask<DVAIBridgeState> GetStateAsync()` snapshot helper. `IAsyncEnumerable<T>` is the idiomatic modern .NET stream — composes with `await foreach`, `System.Linq.Async`, `IAsyncEnumerable<T>.WithCancellation(token)`, and (via `Reactive.Linq.AsyncEnumerable`) Rx if a consumer prefers it. **Polling-free.**
6. Build pipeline: C# source → `dotnet build` clean under `<TreatWarningsAsErrors>true</TreatWarningsAsErrors>` and `<Nullable>enable</Nullable>`. iOS Swift wrapper builds via xcodebuild + Sharpie + `dotnet build` of the binding csproj (CI macos-latest runner). Android binding builds Linux-only (CI ubuntu-latest runner with Android workload installed).

## 2. Non-goals (3G)

- **Native desktop backends (WinUI 3, Avalonia, MAUI desktop)** — Phase 3 ships iOS + Android only. The `DVAIBridge` facade compiles against `net10.0`-base TFM (no platform suffix) to satisfy WinUI / Avalonia / desktop consumers, but every API call throws `BackendUnavailable` at runtime. Native Windows / Linux / macOS LLM backends (e.g. ONNX Runtime, llama.cpp via `LLamaSharp`) are **Phase 4+** territory.
- **Mac Catalyst, tvOS, watchOS** — out of scope. The iOS bindings target `net10.0-ios18.0` only. Mac Catalyst is technically supported by the underlying SwiftPM package but adds a TFM matrix dimension we don't need for v2.4.
- **Xamarin.Forms / classic Xamarin.iOS / Xamarin.Android** — EOL since May 2024. We don't add `xamarin*` TFMs. .NET 10 MAUI consumers and pre-MAUI .NET 8/9 iOS/Android consumers are supported via TFM compatibility (binding projects are compatible with `net8.0-android` / `net8.0-ios` consumers via reference assembly precedence).
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
│   ├── DVAIBridge.iOS/                        # net10.0-ios18.0 binding + Swift wrapper
│   │   ├── DVAIBridge.iOS.csproj              # IsBindingProject=true, NativeReference Swift xcframework
│   │   ├── ApiDefinition.cs                   # [BaseType] DVAIBridgeNetBridge contract
│   │   ├── StructsAndEnums.cs                 # bound enum bridge + struct mappings
│   │   ├── IOSNativeBridge.cs                 # internal — implements INativeBridge by calling Obj-C bindings
│   │   └── native/
│   │       ├── DVAIBridgeNetBridge.swift      # tiny Swift wrapper around DVAIBridge.shared with @objc surface
│   │       ├── Package.swift                  # SwiftPM manifest for the wrapper module (CI builds the xcframework)
│   │       └── build-xcframework.sh           # CI build helper (xcodebuild -create-xcframework)
│   └── DVAIBridge.Android/                    # net10.0-android36.0 binding + Kotlin shim
│       ├── DVAIBridge.Android.csproj          # IsBindingProject=true, AndroidLibrary AAR ref
│       ├── Transforms/
│       │   ├── Metadata.xml                   # mapping rules (suspend → Task, package rename, etc.)
│       │   └── EnumFields.xml                 # BackendKind enum value mapping
│       ├── AndroidNativeBridge.cs             # internal — implements INativeBridge by calling generated bindings
│       └── native/
│           ├── DVAIBridgeAndroidShim.kt       # optional Kotlin coroutine→callback adapter (only if metadata can't do it)
│           └── build.gradle                   # AAR build (delegates to Phase 3D umbrella)
└── tests/
    └── DVAIBridge.Tests/                      # xUnit tests on the facade with INativeBridge mocked
        ├── DVAIBridge.Tests.csproj            # net10.0
        ├── DVAIBridgeFacadeTests.cs
        ├── BackendKindValidationTests.cs
        ├── ProgressEventStreamTests.cs
        └── PlatformExceptionMappingTests.cs
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

### 3.3 Bindings layer sketch — iOS

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

The CI build (`build-xcframework.sh`) wraps it as an `xcframework` with both device and simulator slices, then the `DVAIBridge.iOS.csproj` references it via:

```xml
<ItemGroup>
  <NativeReference Include="native/DVAIBridgeNetBridge.xcframework">
    <Kind>Framework</Kind>
    <SmartLink>True</SmartLink>
    <ForceLoad>True</ForceLoad>
  </NativeReference>
</ItemGroup>
```

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

### 3.5 Cross-platform validation

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

### 3.6 IAsyncEnumerable<ProgressEvent> reactive surface

The facade exposes:

```csharp
public IAsyncEnumerable<ProgressEvent> ProgressEvents { get; }
```

backed by a `Channel<ProgressEvent>` (System.Threading.Channels) populated by an internal subscription to the native bridge's progress callback. Each consumer who calls `await foreach` gets a fresh reader; the writer fans out to all live readers via `Channel<T>.UnboundedChannel + ChannelReader<T>.ReadAllAsync(ct)`. Cancellation propagates: `WithCancellation(ct)` cancels the loop without closing the underlying channel.

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

### 3.7 Threading model

- **Facade**: `Task<T>` async/await throughout. The `Channel<T>` writer is single-writer (one subscription per `INativeBridge` instance), which lets us use the high-throughput `UnboundedChannelOptions { SingleWriter = true }` config.
- **iOS bindings**: each `[Async]`-bound method opens a `Task { ... }` on the Swift side and calls the C# completion handler off the Combine main-actor queue. The bound C# method materializes back as `Task<T>` via the binding generator's `[Async]` synthesis.
- **Android bindings**: the metadata transform rewrites Kotlin's `suspend fun(continuation)` to a `Task<T>`-returning C# method using the binding generator's coroutine adapter (.NET 10 Android workload includes this since .NET 8; the Kotlin shim is a fallback only if the auto-conversion fails for `Flow<ProgressEvent>`).

### 3.8 Test seam

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
| `DVAIBridge` (.NET)         | **NuGet.org**                                 | **public**     |

The .NET package is the third public family member (joining the iOS CocoaPod and the Flutter pub.dev package). The package itself is OSS-friendly; the underlying iOS SwiftPM dep + Android Maven dep are still gated. The iOS binding's xcframework is bundled inside the NuGet (so consumers don't need a separate SwiftPM auth), but the Android binding still requires the consumer's app to add the GitHub Packages Maven repo (because the Android binding consumes the AAR at consumer-build time, not bundles it). Document clearly in the README and consumer guide so .NET MAUI consumers don't expect a one-line `dotnet add package` to be sufficient on Android — they still need a GH PAT for the Maven AAR. See §4.3.

### 4.2 NuGet package contents

Three packages, all sharing the version `2.4.0`:

| Package              | TFM                                  | Contents                                                            |
|----------------------|--------------------------------------|---------------------------------------------------------------------|
| `DVAIBridge`         | `net10.0`                            | facade DLL + xmldoc; declares `<Dependency>` on the iOS + Android slices conditionally by TFM (see below) |
| `DVAIBridge.iOS`     | `net10.0-ios18.0`                    | iOS binding DLL + bundled `DVAIBridgeNetBridge.xcframework` (~3 MB) |
| `DVAIBridge.Android` | `net10.0-android36.0`                | Android binding DLL + transform XML + binding metadata (no AAR — pulled at consumer-build time) |

The facade's `.nuspec` declares conditional dependencies:

```xml
<dependencies>
  <group targetFramework="net10.0" />
  <group targetFramework="net10.0-ios18.0">
    <dependency id="DVAIBridge.iOS" version="[2.4.0]" />
  </group>
  <group targetFramework="net10.0-android36.0">
    <dependency id="DVAIBridge.Android" version="[2.4.0]" />
  </group>
</dependencies>
```

So `dotnet add package DVAIBridge` from a multi-TFM MAUI csproj automatically pulls in the iOS slice when the `net10.0-ios18.0` target is restored and the Android slice when the `net10.0-android36.0` target is restored. WinUI / Avalonia / desktop consumers get the bare facade with no native dependencies — its API throws `BackendUnavailable` at runtime, and the developer experience is "one package, fail-fast on the wrong platform."

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

3G ships under the `2.x.y` line. Phase 3F was tagged at `v2.3.0`; **Phase 3G is `v2.4.0`** (minor bump — additive). The Phase 3D Android umbrella AAR also bumps to 2.4.0 for build-graph consistency (no source changes; just a republish to align the `dvaiBridgeVersion` Gradle property). The Phase 3C iOS umbrella stays at 2.3 (no source changes; the Swift wrapper depends on `DVAIBridge`'s public API which hasn't shifted). The Flutter pub.dev package stays at 2.3 (no source changes).

The .NET assembly + NuGet package version is `2.4.0`. CPM ([Central Package Management](https://learn.microsoft.com/en-us/nuget/consume-packages/central-package-management)) via `Directory.Packages.props` keeps every dep version pinned at one place.

Once 3H (docs/launch) follows it stays at 2.4 (editorial only).

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

8. **WinUI 3 / Avalonia / desktop consumers?** → **Compile-clean, runtime-fail.** The facade's `net10.0`-base TFM means a WinUI / Avalonia / desktop consumer can `dotnet add package DVAIBridge` without errors; calling `StartAsync` throws `DVAIBridgeException(Kind: BackendUnavailable)` with a clear "no native binding for this platform" message. Documented in §3.5. Phase 4 candidate: add a `DVAIBridge.Windows` slice that hosts `LLamaSharp` + the same HTTP shape, so the facade Just Works on Windows too.

9. **Swift wrapper packaging: bundled xcframework vs. separate SwiftPM dep on the consumer side?** → **Bundled xcframework inside `DVAIBridge.iOS.nupkg`.** Consumers should not have to set up SwiftPM credentials to use a NuGet package. CI (`build-xcframework.sh` in `native/`) builds the wrapper xcframework on macos-latest, embeds it in the NuGet via the `<NativeReference>` item, and ships. The wrapper's xcframework includes both device + simulator slices (~3 MB total). We re-publish whenever the underlying SDK ships a major update.

10. **Android shim: required or optional?** → **Optional, default-not-needed.** The Phase 3D AAR's `co.deepvoiceai.bridge.DVAIBridge` is a Kotlin `object` with `suspend fun` methods + `Flow<ProgressEvent>`. The .NET 10 Android workload's binding generator handles `suspend fun` natively (via `kotlinx.coroutines.android`'s continuation adapters that the generator special-cases). For `Flow<ProgressEvent>`, the generator emits a clunky `IFlow` C# wrapper; if that wrapper proves unergonomic during Task 4, we add `DVAIBridgeAndroidShim.kt` with a callback-based `subscribe(listener)` method and bind that instead. Default: no shim; revisit empirically.

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
