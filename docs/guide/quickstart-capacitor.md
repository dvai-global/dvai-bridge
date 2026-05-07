# Quickstart: Capacitor

End-to-end setup for running a local LLM inside a Capacitor 6/7/8 app using
DVAI-Bridge's first-party plugins. By the end of this page your app talks to
an OpenAI-compatible HTTP endpoint served by a native HTTP server bound to
`127.0.0.1`.

## Prerequisites

- A Capacitor 6, 7, or 8 application (`npx cap doctor` should report green).
- Node.js 20+ and `pnpm` (npm / yarn also work).
- iOS: Xcode 16+ with the iOS 17+ SDK. (Apple Foundation Models requires
  iOS 26+ at runtime — see the backend matrix below.)
- Android: Android Studio with NDK r27+ and JDK 21. `compileSdk 35` (or the
  current Capacitor 8 default) on your app module.

## 1. Install the packages

The `@dvai-bridge/capacitor` package is a thin JS routing shim. It does
nothing on its own — you also install one or more **backend** plugins,
each shipping native code:

```bash
# Required: the JS shim + at least one backend.
pnpm add @dvai-bridge/capacitor @dvai-bridge/capacitor-llama

# Optional: framework wrapper.
pnpm add @dvai-bridge/core @dvai-bridge/react   # or @dvai-bridge/vanilla
```

Three backend plugins are available:

| Package | Backend | Platforms | Use when… |
|---|---|---|---|
| `@dvai-bridge/capacitor-llama` | llama.cpp | iOS + Android | You want GGUF model support, broadest model selection, optional vision via `mmproj`. |
| `@dvai-bridge/capacitor-foundation` | Apple Foundation Models | iOS 26+ | You want zero-download text inference on Apple silicon devices. |
| `@dvai-bridge/capacitor-mediapipe` | MediaPipe LLM Inference | Android | You want Google's `.task` runtime including vision-capable Gemma variants. |

Mixing backends is supported — you only `start()` one at a time, but having
both `capacitor-llama` and `capacitor-mediapipe` installed means you can
pick at runtime based on platform or user setting.

## 2. `cap sync`

After installing backend plugins:

```bash
npx cap sync
```

This step is **mandatory**. It does two things:

- **iOS** — adds the plugin's `Package.swift` / podspec to your Xcode
  project. The first build pulls Telegraph (HTTP server) and Swift NIO
  transitively. Run `pnpm cap open ios` and let CocoaPods / SwiftPM
  resolve once.
- **Android** — registers the plugin's Gradle module, merges its
  `AndroidManifest.xml` (which declares the `network_security_config.xml`
  whitelisting cleartext to `127.0.0.1` / `localhost`), and links
  the prebuilt `libllama.so` / MediaPipe native libs.

You do not need to touch your app's `network_security_config.xml`. The
plugin merges its own.

## 3. First-run code

Minimal example, runnable from any framework. This assumes you've used
`@dvai-bridge/capacitor`'s `downloadModel()` helper or shipped a `.gguf`
file via your own download path — see step 4 for the helper.

```ts
import { DVAIBridge } from "@dvai-bridge/capacitor";

const { baseUrl, port, modelId } = await DVAIBridge.start({
  backend: "llama",
  modelPath: "/data/user/0/com.example.app/files/dvai-models/llama-3.2-1b.gguf",
  contextSize: 2048,
  gpuLayers: 99,
  // Optional: override the default port if 38883 is taken.
  // httpBasePort: 38883,
});

console.log(`DVAI ready on ${baseUrl} (model=${modelId})`);
```

`baseUrl` is the local URL — typically `http://127.0.0.1:38883/v1`.
Pass it to any OpenAI-compatible client:

```ts
const res = await fetch(`${baseUrl}/chat/completions`, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    model: modelId,
    messages: [{ role: "user", content: "Why is the sky blue?" }],
    stream: false,
  }),
});
const data = await res.json();
console.log(data.choices[0].message.content);
```

For streaming, set `stream: true` and parse SSE:

```ts
const res = await fetch(`${baseUrl}/chat/completions`, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    model: modelId,
    messages: [{ role: "user", content: "Tell me a story." }],
    stream: true,
  }),
});

const reader = res.body!.getReader();
const decoder = new TextDecoder();
while (true) {
  const { value, done } = await reader.read();
  if (done) break;
  const chunk = decoder.decode(value);
  // Each SSE event begins "data: " and is JSON-encoded.
  // The final event is "data: [DONE]".
  console.log(chunk);
}
```

When the user closes the screen, call `DVAIBridge.stop()` to release the
model and free memory. `stop()` is idempotent.

## 4. Downloading a model with `downloadModel`

Most apps cannot ship multi-GB GGUF files inside the bundle. The shim
includes a resumable, sha256-verified downloader that caches into the
platform-appropriate app-data directory:

```ts
import { DVAIBridge } from "@dvai-bridge/capacitor";

const sub = await DVAIBridge.addProgressListener((e) => {
  if (e.phase === "loading" && e.percent != null) {
    setUiProgress(e.percent);
  }
});

const { path } = await DVAIBridge.downloadModel({
  url: "https://huggingface.co/<org>/<repo>/resolve/main/llama-3.2-1b-instruct.Q4_K_M.gguf",
  sha256: "<lowercase-hex-sha256-of-the-file>",
  destFilename: "llama-3.2-1b.gguf",
  // Optional: gated HF repos.
  // headers: { Authorization: `Bearer ${hfToken}` },
  onProgress: (e) => {
    if (e.bytesTotal) {
      console.log(`${e.bytesReceived}/${e.bytesTotal}`);
    }
  },
});

await sub.remove();

await DVAIBridge.start({ backend: "llama", modelPath: path });
```

Behavior:

- If the file already exists with a matching sha256, returns immediately
  with `{ cached: true }`.
- Otherwise streams an HTTP `Range` download into `<destFilename>.partial`,
  computing sha256 as bytes arrive.
- On final mismatch, deletes the partial + final paths and throws
  `ChecksumMismatchError`. Retry-friendly.
- iOS: marks the file `isExcludedFromBackupKey = true` so it doesn't bloat
  iCloud backups.

For full guidance on hosting, multi-file models, and disk-space
pre-checks, see [Model distribution](./model-distribution.md).

## 5. Common errors

| Symptom | Cause | Fix |
|---|---|---|
| `[DVAI] modelPath is required for backend "llama"` | Caller didn't pass a path. | Provide `modelPath` (or use `downloadModel` first). The `foundation` backend is the exception — it manages the model itself. |
| `[DVAI] Failed to bind any port in range 38883..38898` | Another DVAI instance, dev server, or unrelated process is on those ports. | Pass `httpBasePort: 49000` (or any free port) and bump `httpMaxPortAttempts` if you need a wider scan. |
| `[DVAI] Backend "foundation" selected but the corresponding plugin is not installed` | You called `start({ backend: "foundation" })` without installing `@dvai-bridge/capacitor-foundation`. | Install the matching backend package and re-run `npx cap sync`. |
| `[DVAI] Apple Foundation Models is iOS-only` | Selected `foundation` on Android. | Branch on `Capacitor.getPlatform()` and pick `llama` / `mediapipe` on Android. |
| Cleartext error on Android emulator (API < 28). | Custom `networkSecurityConfig` overrides ours with `cleartextTrafficPermitted=false`. | Either remove your override or merge in `<domain includeSubdomains="true">127.0.0.1</domain>`. The plugin's manifest entry uses `tools:replace` but a host-app explicit override still wins. |

iOS does **not** require any `Info.plist` keys for loopback HTTP —
ATS exempts `127.0.0.1` by default. `NSLocalNetworkUsageDescription` is
unrelated and not needed.

## 6. Choosing a backend

| Need | Recommended backend |
|---|---|
| Text completion, broadest model choice | `llama` |
| Vision (image_url content parts) | `mediapipe` (vision-capable Gemma) or `llama` + mmproj (Phase 2) |
| Audio (input_audio content parts) | `llama` with a multimodal GGUF that has a native audio encoder (Phase 2) |
| Zero-download text on iOS 26+ | `foundation` |
| Embeddings | `llama` with `embeddingMode: true` |
| Apple-managed privacy posture | `foundation` |

See [Multimodal](./multimodal.md) for the full per-backend modality matrix
and content-part shapes, and [Tested models](./tested-models.md) for
concrete model recommendations per tier.

## 7. Distributed inference (`offload`) — v3.0+

Capacitor v3.0+ surfaces the v3.0 distributed-inference configuration.
Pass an `offload` block to `start()` to enable LAN / internet peer
discovery and request offload when local capability is insufficient. See
the [Distributed Inference guide](./distributed-inference.md) for the
full feature description.

```ts
import { DVAIBridge } from "@dvai-bridge/capacitor";

const server = await DVAIBridge.start({
  backend: "llama",
  modelPath: "/path/to/model.gguf",
  offload: {
    enabled: true,
    discoverLAN: true,
    minLocalCapability: 10,
    rendezvousUrl: "wss://rendezvous.myapp.com", // optional, internet path
  },
});
```

The JS-side `OffloadConfig.onPairingRequest` callback cannot cross the
Capacitor plugin boundary, so consumers receive inbound pairing requests
via an event listener and respond via `respondToPairing(requestId, approved)`:

```ts
const handle = await DVAIBridge.addListener("pairingRequest", async (req) => {
  const approved = await myUiConfirm(req.peerDeviceName);
  await DVAIBridge.respondToPairing(req.id, approved);
});

// Tear down when finished:
await handle.remove();
```

`addListener("pairingRequest")` requires a successful `start()` first —
the listener is dispatched on the active backend plugin. Without a
registered listener, inbound pairing requests are denied after the
request's `expiresAt` deadline.

## Next steps

- [Model distribution](./model-distribution.md) — hosting, sha256, multi-file
  GGUF + mmproj download patterns, gated HF repos, disk-space pre-checks.
- [Multimodal](./multimodal.md) — image / audio content parts, error
  semantics, per-backend support matrix.
- [Tested models](./tested-models.md) — the curated list we exercise in CI
  and pre-release smoke tests.
- [Native backend overview](./native-backend.md) — architecture, migration
  notes from the deprecated `llama-cpp-capacitor` package.
- [Distributed Inference guide](./distributed-inference.md) — peer discovery,
  capability scoring, pairing handshake, and the `/v1/dvai/*` endpoints.
