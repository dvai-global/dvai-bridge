# .NET SDK (`DVAIBridge` NuGet family)

`DVAIBridge` is the .NET NuGet family that wraps the
[`@dvai-bridge/ios`](./ios-native-sdk.md) and
[`@dvai-bridge/android`](./android-native-sdk.md) native SDKs **plus** a
desktop-native llama.cpp slice and two cross-platform .NET backends
(ONNX Runtime + ML.NET) behind a single idiomatic C# facade. Drop the
package into a **.NET MAUI**, **Avalonia**, **WinUI 3**, **Mac Catalyst**,
**Xamarin (legacy)**, ASP.NET Core, or console app, call
`DVAIBridge.Shared.StartAsync(...)`, then point any OpenAI-compatible
.NET HTTP client (`Microsoft.SemanticKernel`, `OpenAI` official .NET SDK,
`RestSharp`) at the returned `BaseUrl`.

If you're building with React Native, use
[`@dvai-bridge/react-native`](./react-native-sdk.md). Flutter consumers use
[`dvai_bridge`](./flutter-sdk.md). SwiftUI / Compose apps have direct guides
at [iOS Native SDK](./ios-native-sdk.md) and
[Android Native SDK](./android-native-sdk.md).

## Requirements

- **.NET 10 LTS** (10.0.7 or later — released November 2025, supported through
  November 2028). Earlier .NET 8 / .NET 9 consumers can't consume this package
  directly because the platform-versioned TFMs (`net10.0-ios26.4`,
  `net10.0-maccatalyst26.4`, `net10.0-android36.0`) require a matching .NET 10
  base.
- **iOS 15.1+ runtime floor**, **Mac Catalyst 15.1+ runtime floor**,
  **Android `minSdk 24`**, **Windows 10 1809+ / macOS 11+ / Ubuntu 22.04+** for
  desktop. Same as the underlying native SDKs.
- **Workloads:** `dotnet workload install ios maccatalyst android maui` if
  you're shipping a MAUI app; otherwise just the platform you target. Desktop
  consumers (WinUI / Avalonia / console) need no workload install.

## Install

The `DVAIBridge` family ships **six NuGet packages** to NuGet.org. The
facade (`DVAIBridge`) is the only one most consumers reference directly —
the platform / backend slices are pulled in transitively when needed.

| NuGet                       | Role                                                     | When pulled in                                                |
| --------------------------- | -------------------------------------------------------- | ------------------------------------------------------------- |
| `DVAIBridge`                | Public facade (`DVAIBridge.Shared`, types, exceptions)   | Always — `dotnet add package DVAIBridge`                      |
| `DVAIBridge.iOS`            | iOS + Mac Catalyst binding (xcframework bundled)         | Transitively when csproj has `net10.0-ios26.4` / `…-maccatalyst26.2` |
| `DVAIBridge.Android`        | Android binding (consumer-build AAR fetch)               | Transitively when csproj has `net10.0-android36.0`            |
| `DVAIBridge.Desktop`        | llama.cpp native slice for desktop (Win / macOS / Linux) | Transitively when csproj has bare `net10.0`                   |
| `DVAIBridge.OnnxRuntime`    | ONNX Runtime + GenAI cross-platform backend              | **Opt-in** (`dotnet add package DVAIBridge.OnnxRuntime`)      |
| `DVAIBridge.MLNet`          | ML.NET / OnnxScoringEstimator backend                    | **Opt-in** (`dotnet add package DVAIBridge.MLNet`)            |

```bash
# Most consumers only need this:
dotnet add package DVAIBridge --version 4.0.0

# Optional: cross-platform ONNX Runtime backend (BackendKind.Onnx).
dotnet add package DVAIBridge.OnnxRuntime --version 4.0.0

# Optional: ML.NET backend (BackendKind.MLNet, desktop only).
dotnet add package DVAIBridge.MLNet --version 4.0.0
```

What `dotnet add package DVAIBridge` pulls in transitively:

- **bare `net10.0` (desktop)** → `DVAIBridge.Desktop` (llama.cpp via
  `runtimes/<rid>/native/`).
- **`net10.0-ios26.4` / `net10.0-maccatalyst26.4`** → `DVAIBridge.iOS`
  (single binding NuGet, multi-target). Bundles
  `DVAIBridgeNetBridge.xcframework` inside the NuGet — **no CocoaPods or
  SwiftPM auth required** for iOS / Catalyst consumers.
- **`net10.0-android36.0`** → `DVAIBridge.Android`. The Android binding
  consumes the `co.deepvoiceai:dvai-bridge:4.0.0` AAR at **consumer-build
  time**, so Android consumers still need GitHub Packages Maven configured
  (next section).

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
    Version="4.0.0"
    Repository="https://maven.pkg.github.com/dvai-global/dvai-bridge" />
</ItemGroup>
```

Plus a repo-local or user-global `nuget.config` with credentials:

```xml
<!-- nuget.config (next to your sln; gitignored if it contains secrets) -->
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <add key="github-dvai" value="https://maven.pkg.github.com/dvai-global/dvai-bridge" />
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

iOS, Mac Catalyst, and desktop have no equivalent bootstrap —
`DVAIBridge.Shared` initializes lazily.

## Quickstart

```csharp
using DVAIBridge;

// In your MAUI / Avalonia / WinUI / console view-model:
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

## BackendKind matrix

The cross-platform `BackendKind` enum is the **union** of every backend
the family supports. The facade pre-validates against the runtime
platform; native bindings repeat the check for defense-in-depth.

| `BackendKind` | iOS | Mac Catalyst | Android | Win Desktop | macOS Desktop | Linux Desktop |
| ------------- | :-: | :----------: | :-----: | :---------: | :-----------: | :-----------: |
| `Auto`        | ✓   | ✓            | ✓       | ✓           | ✓             | ✓             |
| `Llama`       | ✓   | ✓            | ✓       | ✓           | ✓             | ✓             |
| `Foundation`  | ✓   | ✓            | ✗       | ✗           | ✗             | ✗             |
| `CoreML`      | ✓   | ✓            | ✗       | ✗           | ✗             | ✗             |
| `MLX`         | ✓   | ✓            | ✗       | ✗           | ✗             | ✗             |
| `MediaPipe`   | ✗   | ✗            | ✓       | ✗           | ✗             | ✗             |
| `LiteRT`      | ✗   | ✗            | ✓       | ✗           | ✗             | ✗             |
| `Onnx`        | ✓   | ✓            | ✓       | ✓           | ✓             | ✓             |
| `MLNet`       | ✗   | ✗            | ✗       | ✓           | ✓             | ✓             |

::: warning MLX under CocoaPods — not applicable here
The .NET package bundles the **xcframework** inside the NuGet, so MLX +
Foundation work for .NET consumers without the CocoaPods caveat that
applies to React Native and Flutter. If you've ever overridden the
`<NativeReference>` to point at a CocoaPods-built `DVAIBridge.framework`,
the same caveat returns — the default is fine.
:::

## Choosing a backend

The decision tree below covers the common consumer profiles. When in
doubt: pick `BackendKind.Auto` and let the facade resolve at runtime.

- **You're a MAUI / Avalonia app shipping cross-platform binaries with
  no platform-specific tuning** → `Auto`. Each platform's runtime resolver
  picks the right native backend from the matrix above.
- **You want broadest model coverage (any GGUF you can find)** → `Llama`.
  Works on every platform; backed by llama.cpp.
- **You're targeting iOS 26+ users and want zero model bundling**
  → `Foundation`. Apple ships the on-device LLM with the OS.
- **You're already shipping `.mlmodelc` artifacts elsewhere in your iOS
  app** → `CoreML` lets you reuse the same converted model.
- **You're an Apple-Silicon-only iPad / Mac app and want maximum
  throughput** → `MLX` (Metal Performance Shaders + Neural Engine).
- **You're an Android app and want Google's first-party LLM runtime**
  → `MediaPipe` (older, broader device support) or `LiteRT` (newer, lower
  latency on Android 14+).
- **You're already pipelining ONNX models elsewhere in your stack and
  want zero new native deps** → `Onnx`. Cross-platform; one model file
  format works everywhere the family runs.
- **You're already inside ML.NET (recommendation, classification,
  forecasting) and want LLM as a transformer in your existing pipeline**
  → `MLNet`. Desktop only; ~1.4× slower than `Onnx` for pure LLM use.

## Per-backend usage

### Llama (default, every platform)

llama.cpp via Metal (iOS / Catalyst), GPU (Android), or
CPU+SIMD/Metal/CUDA (Desktop). Broadest model coverage — any GGUF model
works.

```csharp
var server = await DVAIBridge.Shared.StartAsync(new StartOptions
{
    Backend = BackendKind.Llama,
    ModelPath = "/path/to/llama-3.2-3b-q4_k_m.gguf",
    ContextSize = 4096,
    Threads = 4,
});
```

**Where to get models:** Hugging Face GGUF repos (search "GGUF" + model
family), `llama.cpp` model zoo, or convert with `llama.cpp/convert.py`.

### Foundation (iOS / Mac Catalyst, iOS 26+)

Apple's on-device foundation model exposed via `LanguageModelSession`.
Zero model files to bundle — Apple ships the weights with the OS. iOS
26+ runtime; falls back to `BackendUnavailable` on iOS 25 and older.

```csharp
#if IOS || MACCATALYST
var server = await DVAIBridge.Shared.StartAsync(new StartOptions
{
    Backend = BackendKind.Foundation,
    // No ModelPath — Apple's bundled model is the only option.
});
#endif
```

### CoreML (iOS / Mac Catalyst, iOS 18+)

Apple Neural Engine via `MLModel` + `MLState`. Convert your model with
`coremltools` first; bundle the resulting `.mlmodelc` directory in your
app or copy it to the user's Application Support folder.

```csharp
#if IOS || MACCATALYST
var server = await DVAIBridge.Shared.StartAsync(new StartOptions
{
    Backend = BackendKind.CoreML,
    ModelPath = Path.Combine(NSBundle.MainBundle.BundlePath, "phi-3-mini.mlmodelc"),
});
#endif
```

### MLX (iOS / Mac Catalyst, Apple Silicon)

Apple Silicon GPU + Neural Engine via `mlx-swift-lm`. SwiftPM-only on the
native side; the .NET NuGet wraps the same xcframework so Catalyst /
iOS work transparently. Apple-Silicon device or simulator only.

```csharp
#if IOS || MACCATALYST
var server = await DVAIBridge.Shared.StartAsync(new StartOptions
{
    Backend = BackendKind.MLX,
    ModelPath = "/path/to/mlx-community--Llama-3.2-3B-Instruct-4bit",
});
#endif
```

### MediaPipe (Android only)

Google MediaPipe LLM Inference API. Models distributed as `.bin` task
bundles via [Kaggle Models](https://www.kaggle.com/models?tags=tf-lite).

```csharp
#if ANDROID
var server = await DVAIBridge.Shared.StartAsync(new StartOptions
{
    Backend = BackendKind.MediaPipe,
    ModelPath = Path.Combine(FileSystem.AppDataDirectory, "gemma-2b-it-cpu-int4.bin"),
});
#endif
```

### LiteRT (Android only)

Google LiteRT (TensorFlow Lite Next) inference engine. Models
distributed as `.tflite`. Lower latency than MediaPipe on Android 14+
hardware; older devices can fall back to `MediaPipe` or `Llama`.

```csharp
#if ANDROID
var server = await DVAIBridge.Shared.StartAsync(new StartOptions
{
    Backend = BackendKind.LiteRT,
    ModelPath = Path.Combine(FileSystem.AppDataDirectory, "gemma-2b-it.tflite"),
});
#endif
```

### Onnx (every platform — opt-in NuGet)

ONNX Runtime + GenAI extension. The most portable backend in the
family — same model directory works across iOS, Android, Catalyst,
Windows desktop, macOS desktop, Linux desktop. Requires
`dotnet add package DVAIBridge.OnnxRuntime`.

```csharp
var server = await DVAIBridge.Shared.StartAsync(new StartOptions
{
    Backend = BackendKind.Onnx,
    // Directory containing model.onnx + genai_config.json + tokenizer.json
    ModelPath = "/path/to/Phi-3.5-mini-instruct-onnx",
});
```

**Model format:** ONNX Runtime GenAI expects a directory with at minimum:

- `genai_config.json` — sampling defaults + KV cache shape.
- `model.onnx` (+ optional `model.onnx_data` for >2 GB models).
- `tokenizer.json` — Hugging Face tokenizer config.

**Where to get models:**

- [microsoft/Phi-3.5-mini-instruct-onnx](https://huggingface.co/microsoft/Phi-3.5-mini-instruct-onnx)
  — Microsoft's reference 4-bit GenAI bundle.
- [`onnx-community`](https://huggingface.co/onnx-community) — community
  catalogue of ONNX-converted models, Llama / Mistral / Qwen / etc.
- Convert your own with `optimum-cli export onnx ...` from the
  Hugging Face `optimum` library.

### MLNet (desktop only — opt-in NuGet)

ML.NET via `Microsoft.ML` + `OnnxScoringEstimator`. Use this when
you're **already** running an ML.NET pipeline (recommendation,
classification, forecasting, anomaly detection) and want to add LLM
inference as a stage in the same `IDataView` flow. Greenfield LLM
consumers should pick `Onnx` instead — the underlying ORT natives are
the same, but the ML.NET pipeline shape adds ~1.4× per-token overhead
vs. direct ORT + GenAI.

```csharp
var server = await DVAIBridge.Shared.StartAsync(new StartOptions
{
    Backend = BackendKind.MLNet,
    ModelPath = "/path/to/llama-3.2-1b-instruct.onnx",
    TokenizerPath = "/path/to/tokenizer.json", // optional; defaults next to .onnx
});
```

**Why a separate package?** `Microsoft.ML` (5.0.0) + the OnnxTransformer
chain is a non-trivial transitive dep (~30 MB of managed assemblies plus
the same ORT natives the `Onnx` slice uses). We keep it opt-in so apps
that don't need ML.NET don't pay for it.

## Onnx vs. ML.NET trade-offs

Both backends ride the same ONNX Runtime native today. The choice is
about the **API shape** that fits your app, not about which native is
faster (they're identical at the kernel level).

| Aspect                     | `BackendKind.Onnx` (`DVAIBridge.OnnxRuntime`)        | `BackendKind.MLNet` (`DVAIBridge.MLNet`)               |
| -------------------------- | ---------------------------------------------------- | ------------------------------------------------------ |
| Native runtime             | ORT 1.25 + GenAI 0.13                                | ORT 1.25 (via `OnnxScoringEstimator`)                  |
| Per-token overhead         | Baseline                                             | ~1.4× (pipeline `Fit`/`Transform` per token)           |
| Streaming token API        | Built into GenAI (`Generator.GenerateNextToken`)     | Hand-rolled in the slice (top-k / top-p / temperature) |
| Model format               | GenAI directory (`genai_config.json` + `.onnx`)      | Single `.onnx` + `tokenizer.json` next to it           |
| Mobile (iOS / Android)     | Yes (cross-platform)                                 | No (desktop only)                                      |
| ML.NET pipeline integration | No                                                  | Yes — drop into `EstimatorChain<>`                     |
| Recommended for            | LLM-only apps; mobile + desktop                      | Apps already in ML.NET pipelines                       |

**Recommendation:** use `BackendKind.Onnx` unless you're already in
ML.NET pipelines. The MLNet slice is a compatibility bridge, not a
performance choice.

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

In v2.4 the broadcaster also exits cleanly on consumer-side
cancellation — the loop yield-breaks instead of propagating
`OperationCanceledException` out of `await foreach`. See the
[migration guide](../migration/v2.3-to-v2.4.md) for the behavioral
change.

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

## Distributed inference (offload)

::: tip v3.0
`OffloadConfig` lights up cross-device inference: send a request from a
phone or laptop, run it on a beefier paired peer on the same LAN (or via
a self-hosted rendezvous server). Opt-in — unset `Offload` and the
bridge runs purely on-device exactly as v2.x did.
:::

```csharp
using DVAIBridge;

var server = await DVAIBridge.Shared.StartAsync(new StartOptions
{
    Backend = BackendKind.Auto,
    ModelPath = "/path/to/model.gguf",
    Offload = new OffloadConfig
    {
        Enabled = true,             // master switch — false = pure on-device
        DiscoverLAN = true,         // mDNS browse for sibling devices
        MinLocalCapability = 10.0,  // tok/s threshold below which we look for a peer
        // RendezvousUrl = new Uri("wss://rendezvous.myapp.com"), // optional internet path
        // KnownPeers = new[] { /* PeerInfo entries for kiosk / fleet deployments */ },
        // OnPairingRequest = peer => MyMobileUiConfirm(peer.DeviceName),
    },
});

// Desktop (Avalonia / WinUI / WPF) — consume the streaming pairing surface.
_ = Task.Run(async () =>
{
    await foreach (var req in DVAIBridge.Shared.PairingRequests)
    {
        var approved = await MyDesktopUiConfirm(req.PeerDeviceName);
        await req.RespondAsync(approved);
    }
});

// Snapshot of currently-known + discovered peers.
foreach (var peer in DVAIBridge.Shared.Peers)
{
    Console.WriteLine($"{peer.DeviceName} @ {peer.BaseUrl}");
}
```

`OffloadConfig` fields (every property is optional except where noted):

| Property                 | Type                              | Default            | Purpose                                                                |
| ------------------------ | --------------------------------- | ------------------ | ---------------------------------------------------------------------- |
| `Enabled`                | `bool`                            | `false`            | Master switch — must be `true` for any offload behaviour.              |
| `DiscoverLAN`            | `bool`                            | `true`             | Run mDNS to browse for `_dvai-bridge._tcp` peers on the LAN.           |
| `MinLocalCapability`     | `double`                          | `10.0` (tok/s)     | Below this estimate, the decider tries to route to a peer.             |
| `RendezvousUrl`          | `Uri?`                            | `null`             | Optional `wss://` / `https://` rendezvous server for the internet path.|
| `KnownPeers`             | `IReadOnlyList<PeerInfo>`         | empty              | Pre-known peers — handy for kiosk / fleet deployments.                 |
| `OnPairingRequest`       | `Func<PeerInfo, Task<bool>>?`     | `null` (deny)      | Mobile-friendly approve/deny callback.                                 |

Two host-app surfaces handle pairing:

- **`DVAIBridge.Shared.PairingRequests`** —
  `IAsyncEnumerable<PairingRequest>` for desktop UIs. Resolve each
  request with `await req.RespondAsync(approved)`. Default deny if
  no consumer subscribes.
- **`OffloadConfig.OnPairingRequest`** — async callback for mobile
  apps. Returning `true` approves the pairing; the persisted pairing
  is reused on subsequent requests (HMAC-SHA256 signed via the shared
  pairing key). The callback path takes precedence when both are
  configured.

Persistent state lives under
`Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)/dvai-bridge/`:

| File              | Contents                                                                  |
| ----------------- | ------------------------------------------------------------------------- |
| `device-id.txt`   | Stable 22-char URL-safe per-install device ID (regenerated on reinstall). |
| `capability.json` | First-run probe results — keyed by `(modelId, libraryVersion)`.           |
| `pairings.json`   | Active pairings — peer ID, name, HMAC key, last-used timestamp.           |

Discovery on the desktop slice (`DVAIBridge.Desktop`) is backed by
`Makaretu.Dns.Multicast`. iOS / Android slices delegate to the native
NWBrowser / NsdManager bindings (lit up automatically when those
bindings ship); on a slice without discovery the offload pipeline still
works against `KnownPeers` and the rendezvous path.

::: warning Pairing default
With `Enabled = true` and no `OnPairingRequest` callback **and** no
`PairingRequests` consumer, every incoming pairing request is denied —
a safe default. Wire one of the two surfaces before shipping.
:::

See the [distributed inference guide](./distributed-inference.md) for
the cross-runtime architecture, the
[migration guide](../migration/v2.4-to-v3.0.md) for v2.4 → v3.0
upgrade notes, and `OffloadConfig` /
[`PairingRequest`](https://www.nuget.org/packages/DVAIBridge) on
NuGet.org for the full API reference.

## Threading model

- The `DVAIBridge.Shared` singleton is thread-safe — call from any context.
- `IAsyncEnumerable<ProgressEvent>` is consumer-safe to subscribe from
  multiple threads / view-models simultaneously.
- The internal native dispatcher serializes start/stop through a mutex
  (matching the iOS Swift actor + Android Mutex.withLock pattern). Don't
  call `StartAsync` concurrently with itself; the second call rejects with
  `AlreadyStarted`.

## Desktop deployment

The `DVAIBridge.Desktop` slice ships the llama.cpp native binaries via
NuGet's `runtimes/<rid>/native/` mechanism, so a consumer's
`dotnet publish` automatically copies the right binary into the publish
output:

| Runtime ID         | Native shipped              | Notes                                                  |
| ------------------ | --------------------------- | ------------------------------------------------------ |
| `win-x64`          | `llama.dll` (CPU + AVX2)    | CUDA opt-in via `dotnet add package DVAIBridge.Desktop.CUDA` (Phase 4 candidate). |
| `win-arm64`        | `llama.dll` (CPU + NEON)    | Surface Pro / WSL2 ARM64.                              |
| `osx-arm64`        | `libllama.dylib` (Metal)    | Apple Silicon Macs — Metal-enabled by default.         |
| `osx-x64`          | `libllama.dylib` (CPU)      | Intel Mac fallback.                                    |
| `linux-x64`        | `libllama.so` (CPU + AVX2)  | Ubuntu 22.04+ / Debian 12+.                            |
| `linux-arm64`      | `libllama.so` (CPU + NEON)  | Raspberry Pi 4+, AWS Graviton.                         |

Consumers don't have to do anything — the binary is loaded by P/Invoke
on first call to `StartAsync(BackendKind.Llama)`. If you publish a
self-contained app (`dotnet publish -r win-x64 --self-contained`), the
native is copied into the output `runtimes/` folder automatically.

::: tip CUDA / ROCm
GPU acceleration on desktop is a Phase 4 candidate. v2.4 ships
**CPU-only** Windows / Linux binaries (with AVX2 / NEON SIMD) and
**Metal-enabled** macOS arm64 binaries. CUDA / ROCm builds will land as
opt-in `DVAIBridge.Desktop.CUDA` / `.ROCm` NuGets when Phase 4 closes.
:::

## NativeAOT

Not supported in v2.4. The Obj-C / JNI bindings produce trim warnings the
.NET 10 trimmer can't reason through, and the ML.NET pipeline depends on
reflection emit. Consumers who ship NativeAOT iOS apps can do so with
`<TrimmerRootDescriptor>` overrides; expect a Phase 4 re-spec to land
first-class AOT support.

## Versioning

Follows the family's `2.x.y` line. Phase 3G ships at **v2.4.0** alongside
the Phase 3D Android AAR republish at 2.4.0. Phase 3C iOS umbrella stays
at 2.3 (no source changes). The Flutter plugin stays at 2.3 (no source
changes; Flutter is unaffected by 3G).

## Outgoing offload (v3.2)

`StartAsync` with `Offload = new OffloadConfig { Enabled = true }`
turns on the v3.2 pre-routing proxy in front of the native
backend. Your existing `HttpClient` keeps pointing at
`server.BaseUrl`; the SDK decides per-request whether to serve
locally or forward to a paired peer.

```csharp
var assessment = DVAIBridge.Shared.AssessHardware(
    hardwareMinimum: 3.0,
    minLocalCapability: 10.0);

switch (assessment.Mode)
{
    case PrecheckMode.Ok:
    case PrecheckMode.OffloadOnly:
        await DVAIBridge.Shared.StartAsync(opts);
        break;
    case PrecheckMode.TooWeak:
        ShowCustomNotSupportedDialog(assessment.Reason);
        break;
}
```

The SDK never shows UI for hardware decisions — your app does.
See the [distributed-inference guide](./distributed-inference.md#v32--per-sdk-outgoing-offload-routing)
for the full contract.

> **Status note for v3.2.0**: the .NET-side proxy ships as
> `AssessHardware()` + the v3.0 OffloadSession discovery layer; the
> Kestrel-middleware integration that fully turns on the
> per-request decision in `OpenAIServer` lands in v3.2.x. .NET MAUI
> consumers on iOS / Android already get full proxy routing via
> the native iOS / Android SDKs that ship beneath.

## See also

- [iOS Native SDK](./ios-native-sdk.md) — what this NuGet wraps on iOS / Mac Catalyst.
- [Android Native SDK](./android-native-sdk.md) — what this NuGet wraps
  on Android.
- [Migration v2.3 → v2.4](../migration/v2.3-to-v2.4.md) — distribution
  table delta and additive-only Phase 3G summary.
- NuGet.org pages —
  [`DVAIBridge`](https://www.nuget.org/packages/DVAIBridge) /
  [`DVAIBridge.iOS`](https://www.nuget.org/packages/DVAIBridge.iOS) /
  [`DVAIBridge.Android`](https://www.nuget.org/packages/DVAIBridge.Android) /
  [`DVAIBridge.Desktop`](https://www.nuget.org/packages/DVAIBridge.Desktop) /
  [`DVAIBridge.OnnxRuntime`](https://www.nuget.org/packages/DVAIBridge.OnnxRuntime) /
  [`DVAIBridge.MLNet`](https://www.nuget.org/packages/DVAIBridge.MLNet).
