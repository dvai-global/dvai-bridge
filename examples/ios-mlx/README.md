# `examples/ios-mlx` — iOS native, MLX backend (Apple Silicon)

A SwiftUI app that boots `dvai-bridge` against the MLX backend
([mlx-swift-lm][mlxlm]) using an MLX-converted Llama-3.2-3B-Instruct
4-bit checkpoint pulled from the HuggingFace Hub
([mlx-community/Llama-3.2-3B-Instruct-4bit][ref]).

[mlxlm]: https://github.com/ml-explore/mlx-swift-examples
[ref]: https://huggingface.co/mlx-community/Llama-3.2-3B-Instruct-4bit

## What it shows

- One-line bridge boot with an HF id (no manual download / sha256):
  `DVAIBridge.shared.start(.init(backend: .mlx, modelPath: "<hf-id>"))`.
- mlx-swift-lm handles the download + cache transparently.
- Streaming chat completion via [MacPaw OpenAI Swift SDK][macpaw]
  against `BoundServer.baseUrl`.

[macpaw]: https://github.com/MacPaw/OpenAI

## Prereqs

- **Apple Silicon** Mac (M1+). MLX is GPU/ANE-accelerated via Apple's
  MLX framework; there is no MLX device on x86_64.
- **Xcode 16+** + iPhone 16 simulator on iOS 18.5+. (The package's
  link-time floor is iOS 18.1; mlx-swift-lm itself targets iOS 17+.)
- **SwiftPM-only.** mlx-swift-lm's transitive dependencies don't
  publish CocoaPods specs.

## Open in Xcode

```bash
cd examples/ios-mlx
open Package.swift
```

## What to expect on first run

1. Tap **Load + Ask**.
2. mlx-swift-lm downloads the MLX-converted Llama-3.2-3B-Instruct-4bit
   checkpoint (~1.8 GB) from the HuggingFace Hub into the standard
   `~/Documents/huggingface/` cache (or the simulator's equivalent).
3. The bridge loads the checkpoint via MLX, binds the local server.
4. The MacPaw OpenAI SDK streams a chat completion; tokens appear in
   the scroll view as they arrive.

## Cache location

```
<App Container>/Documents/huggingface/models--mlx-community--Llama-3.2-3B-Instruct-4bit/
```

mlx-swift-lm manages this cache; deleting the directory forces a
re-download. The dvai-bridge `cacheDir()` / `listCachedModels()` /
`deleteCachedModel()` API only manages the GGUF (llama.cpp) cache; MLX
caching is delegated to mlx-swift-lm.

## Smoke test

```bash
bash smoke.sh
```

On Windows/Linux, prints a skip message and exits 0. On Mac, runs
`xcodebuild test`. The test:

- Skips on x86_64 (no MLX device).
- Skips with a clear message if mlx-swift-lm can't start the backend
  in this destination.
- Otherwise asserts the local OpenAI endpoint returns a non-empty
  completion.

`SMOKE_MLX_MODEL_ID` env var overrides the default checkpoint (use a
smaller MLX model in CI for shorter cold-start times).

## Where the code points at the local server

In `Sources/IOSMLXApp/IOSMLXApp.swift`, the `OpenAI` client
construction is the same shape as every other example —
`host: 127.0.0.1`, `port` from `BoundServer.port`, `basePath: "/v1"`.

## Swap the model

Change `mlxModelId` in `IOSMLXApp.swift`. Any HuggingFace MLX-converted
checkpoint works (`mlx-community/*-4bit` is the de-facto repository).
1B / 3B variants are the practical sweet spot for iPhone-class Apple
Silicon; 7B + works on iPad Pro / M1+ Macs.

## See also

- [iOS Native SDK guide](../../docs/guide/ios-native-sdk.md)
- [MLX backend specifics](../../docs/guide/mlx-backend.md)
- [examples/MATRIX.md](../MATRIX.md)
