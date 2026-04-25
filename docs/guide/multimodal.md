# Multimodal

The DVAI-Bridge Capacitor plugins accept OpenAI-shaped content parts.
What actually runs depends on the backend you started and on whether
your loaded model has the matching modality. This page documents the
shapes, the per-backend support matrix, and the exact error wording you
get when a request doesn't fit.

## OpenAI content parts

Each `messages[i].content` is either a plain string or an array of
content parts:

```ts
type ContentPart =
  | { type: "text"; text: string }
  | { type: "image_url"; image_url: { url: string; detail?: "low" | "high" | "auto" } }
  | { type: "input_audio"; input_audio: { data: string; format: AudioFormat } };

type AudioFormat = "pcm16" | "wav" | "mp3" | "m4a" | "aac" | "flac" | "ogg";
```

A multimodal request looks like:

```json
{
  "model": "<modelId>",
  "messages": [
    {
      "role": "user",
      "content": [
        { "type": "text", "text": "What is in this picture?" },
        { "type": "image_url", "image_url": { "url": "data:image/png;base64,iVBOR..." } }
      ]
    }
  ]
}
```

## Per-backend modality matrix

| Modality | `capacitor-llama` | `capacitor-foundation` | `capacitor-mediapipe` |
|---|---|---|---|
| Text | ✅ | ✅ | ✅ |
| Image | ✅ if `mmprojPath` loaded | ❌ | ✅ if vision-capable model |
| Audio | ✅ if model has native audio encoder | ❌ | ❌ |
| Streaming SSE | ✅ | ✅ | ✅ |
| Embeddings | ✅ if `embeddingMode: true` | ❌ | ❌ |

In Phase 1 the most-tested modalities are:

- **Text** on all three backends.
- **Image** on `capacitor-mediapipe` against vision-capable Gemma `.task`
  artifacts. Image support on `capacitor-llama` is wired but the mmproj
  path is gated until Phase 2 verification.
- **Audio** on `capacitor-llama` requires a model whose GGUF has a
  native audio encoder (e.g. Gemma 4 multimodal, Phi-4 Multimodal); the
  pass-through is implemented but verified only on Phase 2 hardware
  budget.

Treat the matrix as the contract; treat Phase 1 verification status as a
caveat layered on top.

## Image content parts

Three URL forms are accepted:

### 1. Data URLs (base64 inline)

```ts
{
  type: "image_url",
  image_url: { url: "data:image/png;base64,iVBORw0KGgoAAAANS..." }
}
```

Best for images already in memory (camera capture, generated previews).
The plugin base64-decodes inline.

### 2. `https://` URLs

```ts
{
  type: "image_url",
  image_url: { url: "https://example.com/cat.jpg" }
}
```

The plugin fetches the URL on the native side (no CORS concerns —
that's a browser-only constraint). Treat any external fetch as
network-dependent and error-prone.

### 3. `file://` URLs

```ts
{
  type: "image_url",
  image_url: { url: "file:///data/.../cache/photo.jpg" }
}
```

Reads directly from app-private storage. Combine with Capacitor's
`Camera` / `Filesystem` plugins for capture flows.

Decoded image bytes are then handed to the backend:

- **`capacitor-llama`** — `mtmd_helper_eval` with the loaded mmproj.
  Decodes PNG / JPEG internally.
- **`capacitor-mediapipe`** — `LlmInferenceSession.addImage(MPImage)`
  on vision-enabled `.task` models.
- **`capacitor-foundation`** — returns 400; not in the current API.

## Audio content parts

```ts
{
  type: "input_audio",
  input_audio: { data: "<base64>", format: "wav" }
}
```

`data` is base64-encoded bytes of the encoded format (or raw PCM samples
for `format: "pcm16"`). The plugin decodes via platform-native APIs
into 16-bit PCM and hands the samples to the backend's audio API.

### Format availability per platform

| Format | iOS | Android |
|---|---|---|
| `pcm16` | ✅ direct | ✅ direct |
| `wav` | ✅ | ✅ |
| `mp3` | ✅ | ✅ |
| `m4a` / `aac` | ✅ | ✅ |
| `flac` | ✅ | ❌ → 400 |
| `ogg` | ❌ → 400 | ✅ |

Decoding paths:

- **iOS** — `AVAudioFile` + `AVAudioConverter` (built-in).
- **Android** — `MediaExtractor` + `MediaCodec` (built-in).

If you target both platforms, `wav` / `mp3` / `m4a` are the safe-by-default
formats. `flac` works only on iOS, `ogg` only on Android.

Backend routing for audio:

- **`capacitor-llama`** — `mtmd_helper_eval_audio` (or current upstream
  equivalent) for models with a native audio encoder.
- **`capacitor-foundation`** — 400; not in the current API.
- **`capacitor-mediapipe`** — 400; no audio-capable tasks in Phase 1.

## Error semantics

When a content part can't be served, the plugin returns one of these
exact-wording responses. Match on these strings if you build user-facing
remediation UI.

| Situation | Status | Body |
|---|---|---|
| Image content part on llama, no mmproj loaded | 400 | `{ "error": "Request includes an image but no mmproj was loaded. Set nativeMmprojPath when starting." }` |
| Image content part on foundation | 400 | `{ "error": "Image input not supported by Apple Foundation Models in this version." }` |
| Audio content part, model without audio encoder | 400 | `{ "error": "Loaded model has no native audio encoder. Use a multimodal model like Gemma 4 or Phi-4 Multimodal." }` |
| Image fetch from `https://` URL fails | 502 | `{ "error": "Failed to fetch image: <reason>" }` |
| Audio decode fails | 400 | `{ "error": "Audio decode failed: <reason>" }` |
| Unsupported audio format | 400 | `{ "error": "Unsupported audio format: <fmt>. Supported on this platform: <list>." }` |

These wordings are spec-pinned and asserted by the cross-language handler
parity tests. They will not change without a CHANGELOG entry.

## Streaming SSE notes

When `stream: true`, all three backends emit OpenAI-shaped chunks. There
is one documented asymmetry across plugins: see
[Handler parity](../development/handler-parity.md) for the gory detail.
For application code that uses an OpenAI SDK or the Vercel AI SDK, this
asymmetry is invisible — those clients tolerate both shapes.

## Phase 1 limitations

- Image and audio pass-through are implemented behind the HTTP boundary
  but the per-modality verification runs on Phase 2's hardware budget
  for `capacitor-llama`. Expect "wired but lightly tested."
- Vision on `capacitor-mediapipe` is the most-tested image path in
  Phase 1.
- `capacitor-foundation` stays text-only until Apple ships a multimodal
  `LanguageModelSession` API.

## See also

- [Capacitor quickstart](./quickstart-capacitor.md) — first-run setup.
- [Tested models](./tested-models.md) — concrete vision / audio model
  recommendations.
- [Handler parity](../development/handler-parity.md) — cross-platform
  SSE-frame asymmetries.
