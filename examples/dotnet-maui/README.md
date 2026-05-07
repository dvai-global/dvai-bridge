# dotnet-maui — DVAIBridge MAUI sample

Single-page .NET MAUI app that hosts a local OpenAI-compatible server
via DVAIBridge and streams a chat completion against it. Runs on
**iOS**, **Android**, and **Mac Catalyst** from one `csproj`.

## What this shows

- Wiring the `DVAIBridge` facade and the `DVAIBridge.iOS` /
  `DVAIBridge.Android` platform slices into a MAUI `csproj` via
  `<ProjectReference>` (path-based — the example tracks the
  in-monorepo .NET projects without a NuGet round-trip).
- Backend selection on each platform:
  - **iOS:** Auto / Llama / Foundation / CoreML / MLX
  - **Mac Catalyst:** Auto / Llama / Foundation / CoreML / MLX / Onnx
  - **Android:** Auto / Llama / MediaPipe / LiteRT
- Streaming a chat completion via `Microsoft.SemanticKernel`
  (OpenAI-compatible client) pointed at `BoundServer.BaseUrl`.
- Calling `DVAIBridge.Android.Bootstrap.Init(ApplicationContext)` in
  `MauiApplication.OnCreate` (required for MediaPipe / downloads).

## Prereqs

- **.NET SDK 10.0.203** (`dotnet --version`).
- **MAUI workload** for your platform set:

  ```bash
  dotnet workload install ios maccatalyst android maui
  ```

- **Android:** JDK 17+, Android SDK with API 36 platform installed
  (workload installer covers most of it; you may need `ANDROID_HOME`).
- **iOS / Mac Catalyst:** Xcode 17+ on a Mac. Build via `ssh mac` from
  Windows.
- **GitHub Packages Maven token** (only when you actually want to bind
  the Android AAR locally — see
  [docs/guide/dotnet-sdk.md](../../docs/guide/dotnet-sdk.md) for the
  `nuget.config` snippet). Without the token the binding falls back to
  the placeholder `Bootstrap.Init`, so the project still **builds**
  cleanly — it just can't actually start the bridge on Android until
  the AAR is fetched.

## Run

```bash
# From the repo root.
cd examples/dotnet-maui

# Build all targets the host can build (Windows: Android only;
# Mac: Android + iOS + Catalyst). Use the smoke script for the matrix.
bash smoke.sh

# Or build one platform manually:
dotnet build -f net10.0-android36.0
# (Mac only)
dotnet build -f net10.0-ios26.2
dotnet build -f net10.0-maccatalyst26.2
```

## On-device flow

1. Launch the app.
2. Pick a backend from the dropdown (defaults to **Auto** — let the
   facade resolve).
3. Optionally type a model path (leave blank for the backend default —
   Foundation needs no model; Llama / Onnx / CoreML / MLX want a path).
4. Tap **Start bridge**. Status label shows the bound URL once the
   embedded Kestrel server is up.
5. Type a prompt and tap **Send chat completion**. Tokens stream into
   the response area.

## Where the OpenAI client points at the local endpoint

[`MainPage.xaml.cs`](./MainPage.xaml.cs) constructs an
`HttpClient` whose `BaseAddress` is `BoundServer.BaseUrl`
(`http://127.0.0.1:<port>/v1`) and feeds it to
`Kernel.AddOpenAIChatCompletion(...)`. Streaming runs through
`IChatCompletionService.GetStreamingChatMessageContentsAsync(...)`.

## Models

| Backend | Model the README assumes you have |
|---|---|
| `Auto` | resolves per-platform |
| `Llama` (iOS / Catalyst / Android / desktop) | any GGUF (Llama-3.2-1B Q4 recommended) |
| `Foundation` (iOS 26+ / Catalyst 26+) | none — Apple ships the weights |
| `CoreML` (iOS / Catalyst) | a `.mlmodelc` from `coremltools` conversion |
| `MLX` (Apple Silicon iOS / Catalyst) | `mlx-community/...-4bit` directory |
| `MediaPipe` (Android) | a `.task` bundle from Kaggle |
| `LiteRT` (Android) | a `.tflite` model |

Models aren't bundled — download once and pass the path.

## Demo flow

[`scripts/demos/dotnet-maui.yaml`](../../scripts/demos/dotnet-maui.yaml)
covers: launch, backend selection, start bridge, send prompt, stream
response.

## Notes

- The `DVAIBridge.OnnxRuntime` slice currently `FrameworkReference`s
  `Microsoft.AspNetCore.App`, whose runtime pack only ships for desktop
  RIDs (`win-*`, `linux-*`, `osx-*`). On the iOS / Android MAUI legs
  the slice fails to restore (NETSDK1082), so this example references
  it only on Mac Catalyst. The cross-platform claim in
  [`docs/guide/dotnet-sdk.md`](../../docs/guide/dotnet-sdk.md) needs
  either (a) a multi-target ONNX slice with conditional Kestrel hosting
  or (b) a docs caveat. Tracked as a Phase 2 library TODO.
