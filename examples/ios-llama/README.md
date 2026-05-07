# `examples/ios-llama` — iOS native, llama.cpp backend

A minimum-viable SwiftUI app that boots `dvai-bridge` against a GGUF
model (Bartowski's Llama-3.2-1B-Instruct, Q4_K_M, ~800 MB), then streams
a chat completion through the [MacPaw OpenAI Swift SDK][macpaw]
pointed at the local server.

[macpaw]: https://github.com/MacPaw/OpenAI

## What it shows

- One-line bridge boot: `DVAIBridge.shared.start(.init(backend: .llama, modelPath: ...))`.
- Idiomatic OpenAI-Swift-SDK usage against `BoundServer.baseUrl`.
- Streaming chat completions (`chatsStream`) rendering token-by-token.
- First-run model download via `DVAIBridge.shared.downloadModel`.

## Prereqs

- macOS host with **Xcode 16+** installed.
- iPhone 16 simulator on iOS 18.5+ (the package floor is iOS 18.1).
- llama.cpp xcframeworks built once for the dvai-bridge submodules:
  ```bash
  cd ../..
  bash scripts/mac-side-prepare-xcframework.sh
  ```
  ~5–15 minutes, one-time per submodule SHA bump.

## Open in Xcode

```bash
cd examples/ios-llama
open Package.swift
```

Xcode resolves the path-deps (`../../packages/dvai-bridge-ios`) and the
SwiftPM dep (`MacPaw/OpenAI`) and lets you run the `IOSLlamaApp`
executable on a simulator. Pick `iPhone 16` as the destination.

## What to expect on first run

1. Tap **Load + Ask**.
2. The bridge downloads `Llama-3.2-1B-Instruct-Q4_K_M.gguf`
   (~800 MB) into the app's caches dir. The status label updates as
   bytes arrive.
3. After download, llama.cpp loads the GGUF (~2–4s on a real device,
   slower on the simulator without Metal).
4. The local server binds at `http://127.0.0.1:38883/v1`.
5. The MacPaw OpenAI SDK streams a chat completion; tokens appear in
   the scroll view as they arrive.

## Cache location

```
<App Container>/Library/Caches/dvai-bridge/models/Llama-3.2-1B-Instruct-Q4_K_M.gguf
```

Delete that file (or call `DVAIBridge.shared.deleteCachedModel(...)`)
to force a re-download.

## Smoke test

```bash
bash smoke.sh
```

On Windows/Linux this prints a skip message and exits 0. On Mac, it
runs `xcodebuild test` against the `IOSLlamaApp` test target. The
test asserts that `POST /v1/chat/completions` returns a non-empty
completion. It needs `SMOKE_MODEL_URL` + `SMOKE_MODEL_SHA256` populated
(via env or `scripts/smoke.local.env`); otherwise it skips cleanly.

## Where the code points at the local server

In `Sources/IOSLlamaApp/IOSLlamaApp.swift`, look for:

```swift
let openAI = OpenAI(configuration: .init(
    token: "sk-local",
    host: host,         // 127.0.0.1
    port: port,         // dvai-bridge picks this — usually 38883
    scheme: "http",
    basePath: "/v1"
))
```

That's the entire integration: the OpenAI SDK doesn't know it's
hitting on-device llama.cpp. From its perspective it's just a
self-hosted OpenAI gateway.

## Swap the model

Change `modelUrl` + `modelSha256` in `IOSLlamaApp.swift`. Any GGUF
that loads in llama.cpp works (the same checkpoint works with
[node-llama-cpp](../../examples/node-langchain) or any llama.cpp
binding). Q4_K_M variants of 1B–3B models are the practical sweet spot
for iPhone-class hardware.

## See also

- [iOS Native SDK guide](../../docs/guide/ios-native-sdk.md) — the
  public-facing quickstart this example mirrors.
- [examples/MATRIX.md](../MATRIX.md) — every (SDK × backend) example
  in the v2.4 matrix.
