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

## Android

| # | SDK | Backend | Path | Smoke | Demo flow | Host requirements |
|---|---|---|---|---|---|---|
| 9 | Android native (Kotlin) | llama.cpp | [`android-llama/`](./android-llama/) | [`android-llama/smoke.sh`](./android-llama/smoke.sh) | [`scripts/demos/android-llama.yaml`](../scripts/demos/android-llama.yaml) | JDK 21+ (Android Studio JBR), Android SDK 35/36, AGP 9.x. End-to-end needs an `arm64-v8a` device + ~770 MB GGUF push. |
| 10 | Android native | MediaPipe LLM | [`android-mediapipe/`](./android-mediapipe/) | [`android-mediapipe/smoke.sh`](./android-mediapipe/smoke.sh) | [`scripts/demos/android-mediapipe.yaml`](../scripts/demos/android-mediapipe.yaml) | Same as #9 plus an `arm64-v8a` device for inference. ~1.3 GB Gemma-2-2B `.task` push for end-to-end. Snapdragon 8 Gen 2+ for QNN delegate. |
| 11 | Android native | LiteRT | [`android-litert/`](./android-litert/) | [`android-litert/smoke.sh`](./android-litert/smoke.sh) | [`scripts/demos/android-litert.yaml`](../scripts/demos/android-litert.yaml) | Same as #9. End-to-end needs the `litert-community/Llama-3.2-1B-Instruct` `.tflite` (~1.0 GB) + matching `tokenizer.json` push. |

## Hybrid

| # | SDK | Backend | Path | Smoke | Demo flow | Host requirements |
|---|---|---|---|---|---|---|
| 12 | Capacitor (iOS+Android) | llama.cpp | [`capacitor-mobile/`](./capacitor-mobile/) | [`capacitor-mobile/smoke.sh`](./capacitor-mobile/smoke.sh) | [`scripts/demos/capacitor.yaml`](../scripts/demos/capacitor.yaml) | Node 22+ for the web bundle; Mac for `cap sync ios`; any host for `cap sync android` |
| 13 | React Native | (delegates — Llama / Foundation / CoreML / MLX / MediaPipe / LiteRT via selector) | [`react-native-app/`](./react-native-app/) | [`react-native-app/smoke.sh`](./react-native-app/smoke.sh) | [`scripts/demos/react-native.yaml`](../scripts/demos/react-native.yaml) | Node 22+ for typecheck + Metro bundle; JDK 21 + Android SDK for `./gradlew assembleDebug` (opt-in via `RUN_ANDROID_BUILD=1`); Mac for `pod install` |
| 14 | Flutter | (delegates — same six via dropdown) | [`flutter-app/`](./flutter-app/) | [`flutter-app/smoke.sh`](./flutter-app/smoke.sh) | [`scripts/demos/flutter.yaml`](../scripts/demos/flutter.yaml) | Flutter 3.39+; Mac for iOS, any host for Android |

## .NET

| # | SDK | Backend | Path | Smoke | Demo flow | Host requirements |
|---|---|---|---|---|---|---|
| 15 | .NET MAUI | Auto / Llama / Foundation / CoreML / MLX / MediaPipe / LiteRT (selector) | [`dotnet-maui/`](./dotnet-maui/) | [`dotnet-maui/smoke.sh`](./dotnet-maui/smoke.sh) | [`scripts/demos/dotnet-maui.yaml`](../scripts/demos/dotnet-maui.yaml) | .NET 10.0.203 + MAUI workload. Android any host; iOS / Catalyst Mac-only via `ssh mac`. |
| 16 | .NET Desktop | llama.cpp (`DVAIBridge.Desktop`) | [`dotnet-desktop-llama/`](./dotnet-desktop-llama/) | [`dotnet-desktop-llama/smoke.sh`](./dotnet-desktop-llama/smoke.sh) | [`scripts/demos/dotnet-desktop-llama.yaml`](../scripts/demos/dotnet-desktop-llama.yaml) | .NET 10.0.203, any desktop OS. GGUF model recommended (~770 MB) for non-smoke runs. |
| 17 | .NET Desktop | ONNX Runtime GenAI (`DVAIBridge.OnnxRuntime`) | [`dotnet-desktop-onnx/`](./dotnet-desktop-onnx/) | [`dotnet-desktop-onnx/smoke.sh`](./dotnet-desktop-onnx/smoke.sh) | [`scripts/demos/dotnet-desktop-onnx.yaml`](../scripts/demos/dotnet-desktop-onnx.yaml) | .NET 10.0.203, any desktop OS. Phi-3-mini ONNX bundle (~2.4 GB) for non-smoke runs. |
| 18 | .NET Desktop | ML.NET / OnnxScoringEstimator (`DVAIBridge.MLNet`) — **classifier on top of OpenAI HTTP API** | [`dotnet-desktop-mlnet/`](./dotnet-desktop-mlnet/) | [`dotnet-desktop-mlnet/smoke.sh`](./dotnet-desktop-mlnet/smoke.sh) | [`scripts/demos/dotnet-desktop-mlnet.yaml`](../scripts/demos/dotnet-desktop-mlnet.yaml) | .NET 10.0.203, any desktop OS. Small ONNX classifier for non-smoke runs. |

---

See [`docs/superpowers/specs/2026-05-07-phase2-examples-matrix-design.md`](../docs/superpowers/specs/2026-05-07-phase2-examples-matrix-design.md)
for the design rationale and per-example contract.
