# `examples/ios-coreml` — iOS native, CoreML / ANE backend

A SwiftUI app that boots `dvai-bridge` against the CoreML backend
using a stateful 4-bit Llama-3.2-1B `.mlpackage` published on
HuggingFace ([finnvoorhees/coreml-Llama-3.2-1B-Instruct-4bit][ref]).

[ref]: https://huggingface.co/finnvoorhees/coreml-Llama-3.2-1B-Instruct-4bit

## Status — experimental

The `.coreml` backend is shipped in v2.x as **experimental**. Model
load + tokenizer load + HTTP-server boot all succeed, but the first
call to `MLModel.prediction(from:using:)` against the reference
checkpoint hits an unrecovered IRValue-format crash inside CoreML's
C++ IR layer. The crash reproduces on both iOS Simulator and
macOS-native and is tracked as the top-priority CoreML follow-up. See
[Known issues][known].

[known]: ../../docs/guide/ios-native-sdk.md#known-issues

This example demonstrates the **integration shape** so consumers can
see the wiring; the actual chat completion may not return until the
upstream bug is fixed. Prefer `.llama` or `.mlx` for production iOS
LLM workloads.

## What it shows

- Multi-file mlpackage download from HF Hub (siblings API +
  `analytics/`, `weights/`, `metadata.json`, `model.mil`,
  `coremldata.bin`).
- Tokenizer download (`tokenizer.json` + optional
  `tokenizer_config.json`).
- One-line bridge boot:
  `DVAIBridge.shared.start(.init(backend: .coreml, modelPath: ..., tokenizerPath: ...))`.
- Idiomatic OpenAI Swift SDK ([MacPaw/OpenAI][macpaw]) against
  `BoundServer.baseUrl`.

[macpaw]: https://github.com/MacPaw/OpenAI

## Prereqs

- macOS host with **Xcode 16+**.
- iPhone 16 simulator on iOS 18.5+ (CoreML state APIs require iOS 18+).
- macOS-native runs require macOS 15+ (`MLState`).

## Open in Xcode

```bash
cd examples/ios-coreml
open Package.swift
```

## What to expect on first run

1. Tap **Load + Ask**.
2. The app discovers the `.mlmodelc` directory via the HF API, then
   downloads ~600 MB of files (4-bit weights + IR graph + tokenizer)
   into the app's caches dir.
3. The bridge loads the CoreML model and binds the local server.
4. **Expected limitation:** the first chat-completion request may not
   return because of the IRValue crash. The status label will show
   the error string surfaced by the bridge.

## Cache location

```
<App Container>/Library/Caches/dvai-coreml-example/
  Llama-3.2-1B-Instruct-4bit.mlmodelc/
  tokenizer/
```

## Smoke test

```bash
bash smoke.sh
```

On Windows/Linux this prints a skip message and exits 0. On Mac, it
runs `xcodebuild test`. The test itself currently `XCTSkip`s while
the IRValue crash is unresolved — re-enable strict assertion once
the upstream fix lands.

## Where the code points at the local server

In `Sources/IOSCoreMLApp/IOSCoreMLApp.swift`, the `OpenAI` client
construction is the same shape as every other example —
`host: 127.0.0.1`, `port` from `BoundServer.port`, `basePath: "/v1"`.

## See also

- [iOS Native SDK guide](../../docs/guide/ios-native-sdk.md)
- [Known issues — CoreML IRValue crash](../../docs/guide/ios-native-sdk.md#known-issues)
- [examples/MATRIX.md](../MATRIX.md)
