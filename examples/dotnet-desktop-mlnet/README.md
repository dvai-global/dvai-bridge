# dotnet-desktop-mlnet — DVAIBridge Desktop ML.NET sample

Console-only desktop app showing the DVAIBridge.MLNet slice hosting an
ONNX **classifier** behind the **same** OpenAI-compatible HTTP API the
rest of the family uses for generative LLMs.

## Why this is interesting

OpenAI-compatible servers are built around generative chat completion.
But the DVAIBridge HTTP shape doesn't actually require generative
output — it requires a request → response with a `completion` field.

When the bound engine is a discriminative model (sentence classifier,
intent router, sentiment scorer, etc.), the "completion" returned by
the server is the predicted **label** instead of a streamed token
sequence. **The same OpenAI-compatible client code** drives both:

```csharp
// Same Microsoft.SemanticKernel call against:
//   - generative LLM bridge → streaming response, e.g. "The sky is blue because…"
//   - classifier bridge     → single completion, e.g. "POSITIVE"
var chat = kernel.GetRequiredService<IChatCompletionService>();
await foreach (var chunk in chat.GetStreamingChatMessageContentsAsync(history))
{
    Console.Write(chunk.Content);
}
```

Why ML.NET specifically? Because ML.NET is the .NET ecosystem's
recommendation / classification / forecasting pipeline framework.
Teams already running ML.NET pipelines who want to add an LLM stage
(or vice versa — add a classification stage to an LLM pipeline)
can do it inside one process with one OpenAI-compatible client.

## What this shows

- The opt-in `DVAIBridge.MLNet` slice end-to-end:
  `BackendKind.MLNet`, an ONNX classifier, the same OpenAI HTTP shape.
- Microsoft.SemanticKernel as the .NET-idiomatic OpenAI client — same
  pattern as the SDK quickstart in
  [`docs/guide/dotnet-sdk.md`](../../docs/guide/dotnet-sdk.md).
- Console-only — no UI; ML.NET classifiers don't need one.

## Prereqs

- **.NET SDK 10.0.203** (`dotnet --version`).
- **An ONNX classifier model** — recommended:
  [ONNX MiniLM sentence classifier](https://huggingface.co/onnx-community)
  or any single-output classifier exported from PyTorch / TF via
  `optimum-cli` or `tf2onnx`.

  ```bash
  # Example (use the smallest classifier you can find — this is a wiring
  # demo, not a benchmark).
  pip install optimum[exporters]
  optimum-cli export onnx \
      --model distilbert-base-uncased-finetuned-sst-2-english \
      ~/models/sst2-distilbert-onnx
  ```

  Then point `DVAI_MODEL_PATH` at the resulting `model.onnx` file.

## Run

```bash
cd examples/dotnet-desktop-mlnet

# Build for your host RID.
dotnet build -c Release

# Direct invocation (single classification → single label):
DVAI_MODEL_PATH=~/models/sst2-distilbert-onnx/model.onnx \
DVAI_PROMPT="The movie was absolutely incredible." \
  dotnet run -c Release

# Or via the smoke script (wiring-only, no model on disk):
bash smoke.sh
```

## Where the OpenAI client points at the local endpoint

[`Program.cs`](./Program.cs) builds an `HttpClient` whose
`BaseAddress = BoundServer.BaseUrl` and feeds it to
`Kernel.AddOpenAIChatCompletion(...)`. The same code drives both
generative and discriminative DVAIBridge backends.

## Demo flow

[`scripts/demos/dotnet-desktop-mlnet.yaml`](../../scripts/demos/dotnet-desktop-mlnet.yaml).

## Notes

- Greenfield LLM consumers should pick `BackendKind.Onnx` over
  `BackendKind.MLNet` — the ML.NET pipeline shape adds ~1.4× per-token
  overhead. The MLNet slice exists for **mixed pipelines** where ML.NET
  is already in place. See the trade-off table in
  [`docs/guide/dotnet-sdk.md`](../../docs/guide/dotnet-sdk.md).
