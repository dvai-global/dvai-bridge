# dotnet-desktop-onnx — DVAIBridge Desktop ONNX Runtime sample

Console + minimal Avalonia 11 desktop app that hosts a local
OpenAI-compatible server via the DVAIBridge.OnnxRuntime slice. Loads
a Microsoft ONNX GenAI model (Phi-3-mini reference bundle) and streams
a chat completion against it.

## What this shows

- The opt-in `DVAIBridge.OnnxRuntime` slice end-to-end:
  `BackendKind.Onnx`, an ONNX GenAI bundle, and the same OpenAI-compatible
  HTTP API the rest of the family exposes.
- Microsoft.SemanticKernel as the .NET-idiomatic OpenAI client — same
  pattern as the SDK quickstart in
  [`docs/guide/dotnet-sdk.md`](../../docs/guide/dotnet-sdk.md).
- ProjectReference (path) into the in-monorepo `DVAIBridge` +
  `DVAIBridge.OnnxRuntime` projects.

## Prereqs

- **.NET SDK 10.0.203** (`dotnet --version`).
- **An ONNX GenAI model bundle** — recommended:
  [`microsoft/Phi-3-mini-4k-instruct-onnx`](https://huggingface.co/microsoft/Phi-3-mini-4k-instruct-onnx)
  (`cpu-int4-rtn-block-32-acc-level-4` ~2.4 GB, or DirectML / CUDA / WebGPU
  variants if your host supports them).

  ```bash
  # One-off download via huggingface-cli:
  pip install huggingface_hub
  huggingface-cli download microsoft/Phi-3-mini-4k-instruct-onnx \
      --include "cpu_and_mobile/cpu-int4-rtn-block-32-acc-level-4/*" \
      --local-dir ~/models/Phi-3-mini-4k-instruct-onnx
  ```

  Then point `DVAI_MODEL_PATH` (or the UI text box) at the directory
  containing `genai_config.json` + `model.onnx` + `tokenizer.json`.

## Run

```bash
cd examples/dotnet-desktop-onnx

# Build for your host RID.
dotnet build -c Release

# UI mode:
dotnet run -c Release

# Headless smoke (no display, expected on CI):
DVAI_HEADLESS=1 DVAI_MODEL_PATH=/path/to/onnx-bundle dotnet run -c Release

# Or via the smoke script:
bash smoke.sh
```

## Where the OpenAI client points at the local endpoint

[`MainWindow.axaml.cs`](./MainWindow.axaml.cs) builds an `HttpClient`
whose `BaseAddress = BoundServer.BaseUrl` and feeds it to
`Kernel.AddOpenAIChatCompletion(...)`. Streaming runs through
`IChatCompletionService.GetStreamingChatMessageContentsAsync(...)`.

## Demo flow

[`scripts/demos/dotnet-desktop-onnx.yaml`](../../scripts/demos/dotnet-desktop-onnx.yaml).

## Notes

- The DVAIBridge.OnnxRuntime slice is documented as cross-platform
  (iOS / Android / desktop) but the csproj currently
  `FrameworkReference`s `Microsoft.AspNetCore.App`, whose runtime pack
  only ships for desktop RIDs. This example is desktop-only as a
  result. Tracked as a Phase 2 library TODO; on iOS / Android you
  reach `BackendKind.Onnx` via the MAUI sample (Catalyst + desktop
  legs only) for now.
