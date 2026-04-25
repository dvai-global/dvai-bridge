# Handler parity

The three Capacitor backend plugins all expose the same OpenAI-compatible
HTTP surface. They must produce **byte-equivalent JSON shapes** for the
same input fixtures. This page documents the shared contract, the one
known SSE-frame asymmetry, and the discipline rule that keeps drift from
silently accumulating.

## The shared contract

Each plugin ships a `*Handlers` type:

| Plugin | Handler type | Bridge dependency |
|---|---|---|
| `capacitor-llama` | `LlamaHandlers` (Swift) / `LlamaHandlers` (Kotlin) | `LlamaCppBridge` / JNI shim |
| `capacitor-foundation` | `FoundationHandlers` (Swift) | `FoundationBridge` (`LanguageModelSession`) |
| `capacitor-mediapipe` | `MediaPipeHandlers` (Kotlin) | `MediaPipeBridge` (`LlmInference`) |

All three implement the same logical handlers:

- `handleChatCompletions` — `POST /v1/chat/completions` (text + content parts).
- `handleCompletions` — `POST /v1/completions` (legacy single-string prompt).
- `handleModels` — `GET /v1/models` (returns the active `modelId`).
- `handleEmbeddings` — `POST /v1/embeddings` (llama-only when
  `embeddingMode: true`; the others return 400).

For a given fixture in `fixtures/transport-fixtures.json`, every
implementation produces:

- The same HTTP status code.
- The same JSON keys at every level.
- The same error wording on documented error paths
  (see [Multimodal § Error semantics](../guide/multimodal.md#error-semantics)).

Cross-language parity is enforced by handler-equivalence tests that all
three platforms run against the same JSON file.

## The legacy `chatToLegacyCompletion` adapter

Each plugin also implements two small adapters:

- `chatToLegacyCompletion` — converts a `chat/completions` request body
  into a `completions` body (single-string prompt).
- `adaptChunkToLegacy` — converts a `chat.completion.chunk` SSE frame
  into a `text_completion` chunk frame.

These are currently **duplicated across all three plugins**. They are a
candidate for extraction into a shared in-language module (Swift
package shared between iOS plugins; Kotlin module shared between Android
plugins). Tracked as a Phase 2 cleanup.

## Per-plugin SSE asymmetry

There is one documented difference in how the three plugins frame SSE
streams. All three are valid OpenAI-compatible streams; SDK clients
tolerate both shapes.

### `LlamaHandlers` (Swift + Kotlin)

Emits a **separate empty-delta finish frame** at the end of the stream:

```
data: {"id":"…","choices":[{"delta":{"content":"final"},"finish_reason":null}]}
data: {"id":"…","choices":[{"delta":{},"finish_reason":"stop"}]}
data: [DONE]
```

This mirrors `llama.cpp`'s upstream convention.

### `MediaPipeHandlers` (Kotlin) and `FoundationHandlers` (Swift)

Fold the finish reason into the **last content frame**:

```
data: {"id":"…","choices":[{"delta":{"content":"final"},"finish_reason":"stop"}]}
data: [DONE]
```

This mirrors how MediaPipe and Foundation Models surface end-of-turn
signals (a single boolean on the final partial result).

### Why we don't normalize

Both shapes are emitted by real OpenAI-compatible servers in the wild.
Forcing one shape would mean inserting a synthetic frame on the
MediaPipe / Foundation side or buffering on the llama side — both add
latency or complexity for no behavioral win. SDK clients (Vercel AI
SDK, official `openai` SDK, LangChain) handle either shape.

If your application code parses raw SSE chunks and assumes a specific
shape, normalize on the client side.

## Error wording parity (spec §8.5)

The exact error strings below are asserted by parity tests across all
three plugins. They will not change without a CHANGELOG entry.

| Situation | Wording |
|---|---|
| Image content part, no mmproj loaded | `Request includes an image but no mmproj was loaded. Set nativeMmprojPath when starting.` |
| Image content part on Foundation | `Image input not supported by Apple Foundation Models in this version.` |
| Audio content part, no audio encoder | `Loaded model has no native audio encoder. Use a multimodal model like Gemma 4 or Phi-4 Multimodal.` |
| Image fetch failure | `Failed to fetch image: <reason>` |
| Audio decode failure | `Audio decode failed: <reason>` |
| Unsupported audio format | `Unsupported audio format: <fmt>. Supported on this platform: <list>.` |

When you add a new error path, add the exact wording in all three
handler implementations + a parity test that loads the same fixture and
asserts each platform returns the same body.

## The discipline rule

When you change any handler logic:

1. Update the matching fixture in `fixtures/transport-fixtures.json`
   (or add a new one).
2. Update **all three** handler implementations to match.
3. Run all three platforms' parity test suites locally before
   committing — TS and Kotlin from any host, Swift via
   [Mac remote builds](./mac-remote-builds.md).
4. CI re-runs the same suites; do not rely on CI to catch parity drift
   that you can catch in seconds locally.

Drift that lands silently because someone updated only the language
they happened to be working in is the failure mode this rule exists
to prevent.

## See also

- [Testing](./testing.md) — how to run each layer.
- [Multimodal](../guide/multimodal.md) — error wordings in user-facing context.
