# .NET SDK (`DVAIBridge` NuGet)

`DVAIBridge` is the .NET NuGet family that wraps the
[`@dvai-bridge/ios`](./ios-native-sdk.md) and
[`@dvai-bridge/android`](./android-native-sdk.md) native SDKs behind a
shared idiomatic C# API. Drop the package into a **.NET MAUI**, **Avalonia**,
**WinUI 3**, or **Xamarin (legacy)** app, call `DVAIBridge.Shared.StartAsync(...)`,
then point any OpenAI-compatible .NET HTTP client (`Microsoft.SemanticKernel`,
`OpenAI` official .NET SDK, `RestSharp`) at the returned `BaseUrl`.

If you're building with React Native, use
[`@dvai-bridge/react-native`](./react-native-sdk.md). Flutter consumers use
[`dvai_bridge`](./flutter-sdk.md). SwiftUI / Compose apps have direct guides
at [iOS Native SDK](./ios-native-sdk.md) and
[Android Native SDK](./android-native-sdk.md).

## Requirements

- **.NET 10 LTS** (10.0.7 or later — released November 2025, supported through
  November 2028). Earlier .NET 8 / .NET 9 consumers can't consume this package
  directly because the platform-versioned TFMs (`net10.0-ios18.0`,
  `net10.0-android36.0`) require a matching .NET 10 base.
- **iOS 15.1+ runtime floor**, **Android `minSdk 24`**. Same as the underlying
  native SDKs.
- **Workloads:** `dotnet workload install ios android maui` if you're shipping
  a MAUI app; otherwise just the platform you target.

## Install

`DVAIBridge` is **published to NuGet.org** — the third public family member
alongside the iOS CocoaPod (`DVAIBridge` on CocoaPods Trunk) and the Flutter
plugin (`dvai_bridge` on pub.dev). Every other family member ships through
GitHub Packages.

```bash
dotnet add package DVAIBridge --version 2.4.0
```

That pulls in:

- `DVAIBridge` (the facade — pure managed C#).
- `DVAIBridge.iOS` (transitively, when your csproj targets `net10.0-ios18.0`).
  Bundles the `DVAIBridgeNetBridge.xcframework` inside the NuGet — **no
  CocoaPods or SwiftPM auth required** for iOS consumers.
- `DVAIBridge.Android` (transitively, when your csproj targets
  `net10.0-android36.0`). The Android binding consumes the
  `co.deepvoiceai:dvai-bridge:2.4.0` AAR at **consumer-build time**, so
  Android consumers still need GitHub Packages Maven configured (next
  section).

::: tip Family asymmetry
The .NET family is the third public registry. iOS bindings ship with the
xcframework bundled in the NuGet (no extra config); the Android binding
slice still requires a GitHub Packages Maven repo entry in the consumer's
csproj. See [migration v2.3 → v2.4](../migration/v2.3-to-v2.4.md) for the
full distribution table.
:::

### Android — consumer csproj

Because the AAR is fetched at consumer-build time (not bundled), your app
csproj needs the Maven repo entry and a personal access token with
`read:packages` scope:

```xml
<!-- YourMauiApp.csproj -->
<ItemGroup Condition="$(TargetFramework.Contains('android'))">
  <AndroidMavenLibrary
    Include="co.deepvoiceai:dvai-bridge"
    Version="2.4.0"
    Repository="https://maven.pkg.github.com/Westenets/dvai-bridge" />
</ItemGroup>
```

Plus a repo-local or user-global `nuget.config` with credentials:

```xml
<!-- nuget.config (next to your sln; gitignored if it contains secrets) -->
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <add key="github-dvai" value="https://maven.pkg.github.com/Westenets/dvai-bridge" />
  </packageSources>
  <packageSourceCredentials>
    <github-dvai>
      <add key="Username" value="%GITHUB_USER%" />
      <add key="ClearTextPassword" value="%GITHUB_TOKEN%" />
    </github-dvai>
  </packageSourceCredentials>
</configuration>
```

Then export `GITHUB_USER` + `GITHUB_TOKEN` (or use environment-specific
secrets in CI). Same friction Flutter consumers see in 3F.

### Android — bootstrap

Call `DVAIBridge.Android.Bootstrap.Init(applicationContext)` once from
your `MauiApplication`'s `OnCreate` override. Required for the MediaPipe
backend and for `DownloadModelAsync`.

```csharp
// Platforms/Android/MainApplication.cs
using Android.App;
using Android.Runtime;

[Application]
public class MainApplication : MauiApplication
{
    public MainApplication(IntPtr handle, JniHandleOwnership ownership)
        : base(handle, ownership) { }

    public override void OnCreate()
    {
        base.OnCreate();
#if ANDROID
        DVAIBridge.Android.Bootstrap.Init(ApplicationContext!);
#endif
    }

    protected override MauiApp CreateMauiApp() => MauiProgram.CreateMauiApp();
}
```

iOS has no equivalent bootstrap — `DVAIBridge.Shared` initializes lazily.

## Quickstart

```csharp
using DVAIBridge;

// In your MAUI / Avalonia view-model:
public sealed class ChatViewModel : INotifyPropertyChanged
{
    public async Task LoadModelAsync(CancellationToken ct = default)
    {
        var server = await DVAIBridge.Shared.StartAsync(new StartOptions
        {
            Backend = BackendKind.Auto,
            ModelPath = await ResolveModelPathAsync(),
            ContextSize = 2048,
            Threads = 4,
        }, ct);

        // Point your OpenAI-compatible client at server.BaseUrl.
        var openAi = new OpenAIClient(new ApiKeyCredential("local-stub"),
            new OpenAIClientOptions { Endpoint = new Uri(server.BaseUrl) });

        var chatClient = openAi.GetChatClient(server.ModelId);
        var response = await chatClient.CompleteChatAsync(
            new ChatMessage[] { ChatMessage.CreateUserMessage("Hi!") }, cancellationToken: ct);

        Console.WriteLine(response.Value.Content[0].Text);
    }

    public async Task ShutdownAsync() =>
        await DVAIBridge.Shared.StopAsync();
}
```

## BackendKind

The cross-platform `BackendKind` enum is the **union** of iOS + Android
options. The facade pre-validates against the runtime platform; native
bindings repeat the check for defense-in-depth.

| Value                  | iOS | Android | Notes                                                     |
| ---------------------- | :-: | :-----: | --------------------------------------------------------- |
| `BackendKind.Auto`     |  ✅ |   ✅    | Resolves the best available backend.                      |
| `BackendKind.Llama`    |  ✅ |   ✅    | llama.cpp via Metal (iOS) / GPU (Android). Default.       |
| `BackendKind.Foundation` | ✅ |        | Apple Foundation Models. iOS 26+. SwiftPM-only.            |
| `BackendKind.CoreML`   |  ✅ |        | Apple Neural Engine via `MLModel`. iOS 18+.                |
| `BackendKind.MLX`      |  ✅ |        | Apple Silicon via `mlx-swift-lm`. SwiftPM-only.            |
| `BackendKind.MediaPipe` |     |   ✅    | Google MediaPipe LLM Inference API.                        |
| `BackendKind.LiteRT`   |     |   ✅    | Google LiteRT (TensorFlow Lite Next).                      |

::: warning MLX under CocoaPods — not applicable here
The .NET package bundles the **xcframework** inside the NuGet, so MLX +
Foundation work for .NET consumers without the CocoaPods caveat that
applies to React Native and Flutter. If you've ever overridden the
`<NativeReference>` to point at a CocoaPods-built `DVAIBridge.framework`,
the same caveat returns — the default is fine.
:::

## Reactive progress events

`DVAIBridge.Shared.ProgressEvents` is an
`IAsyncEnumerable<ProgressEvent>` — the modern .NET idiom for push-style
streams (used by `Microsoft.Extensions.AI`, `Microsoft.SemanticKernel`,
`SignalR`, and `System.IO.Pipelines`). Consume with `await foreach`:

```csharp
using var cts = new CancellationTokenSource();

_ = Task.Run(async () =>
{
    await foreach (var ev in DVAIBridge.Shared.ProgressEvents
                     .WithCancellation(cts.Token))
    {
        Debug.WriteLine($"{ev.Kind} {ev.Phase} {ev.Percent ?? 0}%");
    }
});

await DVAIBridge.Shared.DownloadModelAsync(new DownloadOptions(
    Url: "https://huggingface.co/.../model.gguf",
    Sha256: "abcdef..."));

cts.Cancel();
```

The broadcaster is **multi-consumer-safe**: every `await foreach` call
gets its own bounded channel, and the writer fans every event out to all
of them. Slow consumers drop oldest events when their channel hits 64
items rather than blocking the writer or other consumers.

### Rx.NET interop

If you prefer `IObservable<T>` for view-binding pipelines, convert with
`System.Linq.Async`:

```csharp
using System.Reactive.Linq; // requires `dotnet add package System.Reactive`

IObservable<ProgressEvent> rx = DVAIBridge.Shared.ProgressEvents
    .ToObservable();
```

That's a 40 KB transitive dep — we don't bundle it by default.

## Snapshot state

Useful for binding a view-model "is the bridge running?" checkbox without
subscribing to the stream:

```csharp
var state = await DVAIBridge.Shared.GetStateAsync();
if (state.IsReady)
    Console.WriteLine($"Bound at {state.BaseUrl}");
if (state.LastError is { } err)
    Console.WriteLine($"Last error: {err.Kind} {err.Message}");
```

## Errors

Every public method throws `DVAIBridgeException` on failure. The
`Kind` discriminator is exhaustive:

| `DVAIBridgeErrorKind`       | When                                                          | Recovery                                                            |
| --------------------------- | ------------------------------------------------------------- | ------------------------------------------------------------------- |
| `AlreadyStarted`            | `StartAsync` while a previous start is still bound.           | Call `StopAsync` first.                                             |
| `ConfigurationInvalid`      | Bad `StartOptions` field (missing path, unknown backend…).    | Fix the options; the `Details["reason"]` says what was wrong.       |
| `ModelLoadFailed`           | The selected backend rejected the model file.                 | Try a different model or backend.                                   |
| `BackendUnavailable`        | Backend not supported on this device or build configuration.  | Pick a supported `BackendKind` for your platform.                   |
| `BackendError`              | Native steady-state failure (catch-all).                      | Inspect `InnerException`; consider restart.                         |
| `ChecksumMismatch`          | Downloaded sha256 didn't match `DownloadOptions.Sha256`.      | Re-issue the download or verify the canonical sha256 elsewhere.     |
| `DownloadFailed`            | Network or filesystem error during download.                  | Retry with backoff; check `Details["reason"]` for the inner cause.  |

## Threading model

- The `DVAIBridge.Shared` singleton is thread-safe — call from any context.
- `IAsyncEnumerable<ProgressEvent>` is consumer-safe to subscribe from
  multiple threads / view-models simultaneously.
- The internal native dispatcher serializes start/stop through a mutex
  (matching the iOS Swift actor + Android Mutex.withLock pattern). Don't
  call `StartAsync` concurrently with itself; the second call rejects with
  `AlreadyStarted`.

## Desktop (WinUI 3 / Avalonia / desktop .NET)

The facade compiles cleanly against bare `net10.0`, so a WinUI / Avalonia
/ Blazor app can `dotnet add package DVAIBridge` without errors. Every
API call throws `DVAIBridgeException(BackendUnavailable)` at runtime with
a clear "no native binding for this platform" message — fail-fast, no
partial-init weirdness.

Native desktop backends (Windows, macOS, Linux) are a **Phase 4
candidate**, likely via `LLamaSharp` (llama.cpp's .NET binding) plus the
same HTTP-server shape so the facade Just Works.

## NativeAOT

Not supported in v2.4. The Obj-C / JNI bindings produce trim warnings the
.NET 10 trimmer can't reason through. Consumers who ship NativeAOT iOS
apps can do so with `<TrimmerRootDescriptor>` overrides; expect a Phase 4
re-spec to land first-class AOT support.

## Versioning

Follows the family's `2.x.y` line. Phase 3G ships at **v2.4.0** alongside
the Phase 3D Android AAR republish at 2.4.0. Phase 3C iOS umbrella stays
at 2.3 (no source changes). The Flutter plugin stays at 2.3 (no source
changes; Flutter is unaffected by 3G).

## See also

- [iOS Native SDK](./ios-native-sdk.md) — what this NuGet wraps on iOS.
- [Android Native SDK](./android-native-sdk.md) — what this NuGet wraps
  on Android.
- [Migration v2.3 → v2.4](../migration/v2.3-to-v2.4.md) — distribution
  table delta and additive-only Phase 3G summary.
- NuGet.org pages —
  [`DVAIBridge`](https://www.nuget.org/packages/DVAIBridge) /
  [`DVAIBridge.iOS`](https://www.nuget.org/packages/DVAIBridge.iOS) /
  [`DVAIBridge.Android`](https://www.nuget.org/packages/DVAIBridge.Android).
