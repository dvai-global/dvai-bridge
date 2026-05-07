# dotnet-desktop-llama — DVAIBridge desktop Llama (llama.cpp) sample

Console + minimal Avalonia 11 UI desktop app that hosts a local
OpenAI-compatible server via DVAIBridge.Desktop (the llama.cpp slice)
and streams a chat completion against it.

## What this shows

- The desktop SDK quickstart from
  [`docs/guide/dotnet-sdk.md`](../../docs/guide/dotnet-sdk.md), end to
  end: `DVAIBridge.Shared.StartAsync(BackendKind.Llama, ModelPath = ...)`,
  bound `BoundServer.BaseUrl`, streaming via Microsoft.SemanticKernel.
- ProjectReference (path) into the in-monorepo `DVAIBridge` +
  `DVAIBridge.Desktop` projects (no NuGet round-trip).
- Cross-platform packaging via `<RuntimeIdentifiers>win-x64;…;linux-arm64`.
- A headless smoke path (`--headless` / `DVAI_HEADLESS=1`) for CI.

## Prereqs

- **.NET SDK 10.0.203** (`dotnet --version`).
- **A GGUF model** — recommended:
  [Llama-3.2-1B-Instruct Q4_K_M](https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/blob/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf)
  (~770 MB).

The first time you build, NuGet restores the
`DVAIBridge.Desktop` project's `runtimes/<rid>/native/` directory only
if you've populated it via the upstream fetch script:

```bash
bash packages/dvai-bridge-dotnet/src/DVAIBridge.Desktop/scripts/fetch-llama-binaries.sh
```

Without the natives, the project still **builds** (the `<Content>`
include is conditional), but the headless smoke path exits with
`ModelLoadFailed` rather than an actual completion — that's the
expected wiring-only verification.

## Run

```bash
cd examples/dotnet-desktop-llama

# Build for your host RID.
dotnet build -c Release

# UI mode:
dotnet run -c Release

# Headless smoke (no display, expected on CI):
DVAI_HEADLESS=1 DVAI_MODEL_PATH=/path/to/model.gguf dotnet run -c Release

# Or via the smoke script:
bash smoke.sh
```

## Where the OpenAI client points at the local endpoint

[`MainWindow.axaml.cs`](./MainWindow.axaml.cs) builds an `HttpClient`
whose `BaseAddress = BoundServer.BaseUrl` (`http://127.0.0.1:<port>/v1`)
and feeds it to
`Kernel.CreateBuilder().AddOpenAIChatCompletion(...)`. Streaming runs
through `IChatCompletionService.GetStreamingChatMessageContentsAsync(...)`.

## Demo flow

[`scripts/demos/dotnet-desktop-llama.yaml`](../../scripts/demos/dotnet-desktop-llama.yaml).

## Notes

- `Avalonia 11.3.14` was chosen over Avalonia 12.x — 12 just shipped
  and the binding ergonomics around .NET 10 are still settling. The 11
  line is mature against .NET 10.
- The desktop slice's native pack is RID-keyed: a build for
  `linux-arm64` won't carry the `win-x64` `llama.dll`. If you publish
  self-contained for a specific RID via
  `dotnet publish -c Release -r win-x64 --self-contained`, NuGet copies
  only the matching native into the publish output.
