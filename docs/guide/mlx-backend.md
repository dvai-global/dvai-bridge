# MLX Backend

[MLX](https://github.com/ml-explore/mlx) is Apple's array framework for
Apple Silicon (iOS / iPadOS / macOS / visionOS). The MLX backend in
dvai-bridge runs LLM inference on-device via Apple's GPU + Neural
Engine through [`mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm).

## When to use it

| Use MLX when… | Use a different backend when… |
|---|---|
| You want top-tier speed on Apple Silicon. | You're on iOS Simulator on an Intel Mac. |
| Your model is published as an MLX-converted HF checkpoint (`mlx-community/...`). | You only have a GGUF file. → use `.llama`. |
| You're already using SwiftPM. | You're on CocoaPods. → use `.llama` or `.coreml`. |
| You don't need embeddings. | You need embeddings. → use `.llama` with `embeddingMode: true`. |

## Constraints

- **Apple Silicon only at runtime.** MLX uses Metal Performance Shaders;
  iOS Simulator running on Intel Mac hosts has no MLX device. Real iOS
  devices and iOS Simulator on Apple-Silicon Macs work.
- **iOS 17+ at link time.** `@dvai-bridge/ios-mlx-core` declares
  `.iOS(.v17)` (mlx-swift-lm's own minimum). The umbrella
  `@dvai-bridge/ios` package's iOS-18.1 floor still applies for
  consumers using the bridge through `DVAIBridge.shared`.
- **SwiftPM only.** `mlx-swift-lm`'s transitive Swift dependencies
  (mlx-swift, swift-syntax) don't publish CocoaPods specs. Selecting
  `.mlx` under a CocoaPods build of dvai-bridge throws
  `DVAIBridgeError.backendUnavailable(.mlx, …)`. CocoaPods consumers
  should pick `.llama` or `.coreml` instead.
- **No embeddings.** The MLX handler returns HTTP 501 on `/v1/embeddings`.
  Use `.llama` with `embeddingMode: true` if you need embeddings.

## Quick start

### Native iOS app (SwiftPM)

```swift
import DVAIBridge

let server = try await DVAIBridge.shared.start(.init(
    backend: .mlx,
    modelPath: "mlx-community/Llama-3.2-1B-Instruct-4bit"
))
```

The `modelPath` is a HuggingFace model identifier — **not a local file
path**. The first `start()` downloads the weights into the user's local
HuggingFace cache (`~/Library/Caches/huggingface/hub/...` on macOS;
sandboxed equivalent on iOS). Subsequent `start()` calls hit the cache.

### Capacitor app (`@dvai-bridge/capacitor-mlx`)

```ts
import DVAIBridge from "@dvai-bridge/capacitor";

await DVAIBridge.start({
    backend: "mlx",
    modelPath: "mlx-community/Llama-3.2-1B-Instruct-4bit",
});
```

Then point your OpenAI client at the returned `baseUrl` exactly like
any other backend. The Capacitor MLX plugin is iOS-only — selecting
`mlx` on Android throws an `iOS-only` error.

## Picking a model

Look for repos under [`mlx-community`](https://huggingface.co/mlx-community)
on HuggingFace. The reference 4-bit Llama-3.2-1B is
[`mlx-community/Llama-3.2-1B-Instruct-4bit`](https://huggingface.co/mlx-community/Llama-3.2-1B-Instruct-4bit)
(~700 MB).

Other tested options (sizes are 4-bit quantized):

| Repo | Size | Notes |
|---|---|---|
| `mlx-community/Llama-3.2-1B-Instruct-4bit` | ~700 MB | The reference / smoke-test default. |
| `mlx-community/Llama-3.2-3B-Instruct-4bit` | ~1.8 GB | Better quality; significantly heavier. |
| `mlx-community/Mistral-7B-Instruct-v0.3-4bit` | ~4.1 GB | 7 B class; needs ample RAM on iOS. |
| `mlx-community/Qwen3-4B-4bit` | ~2.4 GB | Strong multi-lingual + tool-use. |

You can also convert your own HF checkpoint to MLX using
[`mlx_lm.convert`](https://github.com/ml-explore/mlx-examples/tree/main/llms#using-the-cli)
on a Python host once, then publish the result to HuggingFace and load
it from your dvai-bridge app.

## Multi-turn vs stateless

dvai-bridge's HTTP surface is stateless — each `/v1/chat/completions`
request includes the entire message history. The MLX backend's
underlying [`ChatSession`](https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXLMCommon/ChatSession.swift)
*can* maintain conversational state internally for higher throughput,
but doing so would conflict with our stateless HTTP semantics. The
current handler flattens the incoming `messages` array into a single
prompt on every request and re-applies the model's chat template via
`ChatSession`'s built-in template path.

If your app has a clear "single conversation per session" model and
you'd benefit from keeping the cache hot across requests, that's a
reasonable Phase 4 enhancement — file an issue.

## Streaming

Set `stream: true` in the chat-completion request body. The MLX handler
forwards `mlx-swift-lm`'s token stream as OpenAI-style SSE deltas:

```ts
const res = await fetch(`${baseUrl}/chat/completions`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
        messages: [{ role: "user", content: "Hello" }],
        stream: true,
    }),
});
const reader = res.body!.getReader();
// each chunk is `data: {…}\n\n`
```

## Limitations + known gotchas

- **Concurrency**: `ChatSession` is not thread-safe. The current handler
  serializes requests through a single in-flight task; high-concurrency
  workloads will queue. Phase 3D may add a session pool.
- **No tool/function calling on the HTTP surface yet.** `ChatSession`
  supports tool use natively, but the dvai-bridge HTTP handler doesn't
  forward `tools` from the request body. Open an issue if you need it.
- **Cache eviction is HF-Hub's responsibility.** dvai-bridge doesn't
  expose `listCachedModels()` / `deleteCachedModel()` for the MLX cache
  — those methods on `DVAIBridge.shared` apply to the GGUF/llama cache
  only. To clear MLX models, delete the HF Hub cache directory directly.
- **First-run download is on the network**. Plan for a first-launch
  experience that surfaces download progress (the bridge's
  `progressStream` reports phase but not byte-level progress for MLX
  downloads — that's a Phase 3D follow-up).

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `start()` throws "MLX model load failed" with `metal device not available` | iOS Simulator on Intel Mac, or a device without an Apple Silicon GPU. Use a real device or Apple-Silicon simulator. |
| `start()` hangs on first call | First-time download of the model (~700 MB to several GB). Watch the `progressStream`. |
| Chat replies are empty | The model may need additional `instructions:` to elicit non-empty output. Pass them through the chat-completion `messages` array as a `system` role. |
| `select(.mlx)` works on SwiftPM but not CocoaPods | Expected — see [Constraints](#constraints) above. |

## Reference

- [iOS Native SDK guide](./ios-native-sdk.md) for installation + general SDK usage.
- [`mlx-swift-lm` API docs](https://swiftpackageindex.com/ml-explore/mlx-swift-lm) for advanced model configuration.
