# Examples matrix

Tracks every (SDK × backend) combination dvai-bridge supports. Each
combo gets one example app, one demo YAML, and one host-gated smoke
test. CI drift-checks this table against `scripts/demos/` and the
filesystem so missing examples surface as a build failure.

The matrix is being built out incrementally as part of post-v2.4 Phase
2; rows for examples that haven't shipped yet are marked **planned**.

## Web / Node

| # | SDK | Backend | Path | Smoke | Demo flow | Host requirements |
|---|---|---|---|---|---|---|
| 1 | Web (React) | Transformers.js | [`web-react/`](./web-react/) | (interactive) | [`scripts/demos/web-react.yaml`](../scripts/demos/web-react.yaml) | Any with WebGPU-capable browser |
| 2 | Web (vanilla, no build) | Transformers.js | [`web-vanilla-cdn/`](./web-vanilla-cdn/) | [`web-vanilla-cdn/smoke.sh`](./web-vanilla-cdn/smoke.sh) | [`scripts/demos/web-vanilla-cdn.yaml`](../scripts/demos/web-vanilla-cdn.yaml) | Any with a static-file server (`python -m http.server`) |
| 3 | Node | Transformers.js | [`node-langchain/`](./node-langchain/) | (planned) | [`scripts/demos/web-react.yaml`](../scripts/demos/web-react.yaml) | Node 22+ |
| 4 | Node | llama.cpp (`node-llama-cpp`) | [`node-llama-cpp/`](./node-llama-cpp/) | [`node-llama-cpp/smoke.sh`](./node-llama-cpp/smoke.sh) | [`scripts/demos/node-llama-cpp.yaml`](../scripts/demos/node-llama-cpp.yaml) | Node 22+, ~1 GB free disk for the GGUF |

## Web / Node — planned

| # | SDK | Backend | Status |
|---|---|---|---|
| 2a | Web (React) | WebLLM | planned (Phase 2 follow-up) |

## iOS

| # | SDK | Backend | Path | Smoke | Demo flow | Host requirements |
|---|---|---|---|---|---|---|
| 5 | iOS native (Swift) | llama.cpp | [`ios-llama/`](./ios-llama/) | [`ios-llama/smoke.sh`](./ios-llama/smoke.sh) | [`scripts/demos/ios-llama.yaml`](../scripts/demos/ios-llama.yaml) | Mac + Xcode 16+, iPhone 16 sim on iOS 18.5+, ~800 MB GGUF cache |
| 6 | iOS native | Foundation Models | [`ios-foundation/`](./ios-foundation/) | [`ios-foundation/smoke.sh`](./ios-foundation/smoke.sh) | [`scripts/demos/ios-foundation.yaml`](../scripts/demos/ios-foundation.yaml) | Mac + Xcode 16+, **iOS 26+ runtime** to actually exercise (XCTSkip otherwise). SwiftPM-only. |
| 7 | iOS native | CoreML | [`ios-coreml/`](./ios-coreml/) | [`ios-coreml/smoke.sh`](./ios-coreml/smoke.sh) | [`scripts/demos/ios-coreml.yaml`](../scripts/demos/ios-coreml.yaml) | Mac + Xcode 16+, iPhone 16 sim on iOS 18.5+. **Experimental — known IRValue crash; smoke gated.** |
| 8 | iOS native | MLX | [`ios-mlx/`](./ios-mlx/) | [`ios-mlx/smoke.sh`](./ios-mlx/smoke.sh) | [`scripts/demos/ios-mlx.yaml`](../scripts/demos/ios-mlx.yaml) | **Apple Silicon Mac** + Xcode 16+, iPhone 16 sim on iOS 18.5+, ~1.8 GB MLX HF cache. SwiftPM-only. |

## Android — planned

| # | SDK | Backend | Status |
|---|---|---|---|
| 9 | Android native (Kotlin) | llama.cpp | planned |
| 10 | Android native | MediaPipe LLM | planned |
| 11 | Android native | LiteRT | planned |

## Hybrid — planned

| # | SDK | Backend | Status |
|---|---|---|---|
| 12 | Capacitor (iOS+Android) | llama.cpp | planned |
| 13 | React Native | (delegates) | planned |
| 14 | Flutter | (delegates) | planned |

## .NET — planned

| # | SDK | Backend | Status |
|---|---|---|---|
| 15 | .NET MAUI | (delegates) | planned |
| 16 | .NET Desktop | llama.cpp | planned |
| 17 | .NET Desktop | ONNX Runtime GenAI | planned |
| 18 | .NET Desktop | ML.NET | planned |

---

See [`docs/superpowers/specs/2026-05-07-phase2-examples-matrix-design.md`](../docs/superpowers/specs/2026-05-07-phase2-examples-matrix-design.md)
for the design rationale and per-example contract.
