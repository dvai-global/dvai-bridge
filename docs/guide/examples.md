# Example apps

DVAI-Bridge ships 18 runnable example apps covering every (SDK ×
backend) pair. Each example is a complete project with its own
manifest (`package.json`, `Package.swift`, `build.gradle.kts`,
`pubspec.yaml`, `.csproj`) and a `smoke.sh` that boots a wiring-only
test you can run on CI.

Source: [`examples/`](https://github.com/Westenets/dvai-bridge/tree/main/examples)
in the monorepo. Group-by-SDK below.

## Prerequisites (all examples)

```bash
# One-time, from the repo root:
git clone https://github.com/Westenets/dvai-bridge.git
cd dvai-bridge
pnpm install --ignore-scripts
```

Native examples additionally need the native SDK published locally:

```bash
# Android: publish the workspace AAR to ~/.m2/
pwsh scripts/android-publish-local.ps1    # Windows
bash scripts/android-publish-local.sh     # Mac / Linux

# iOS: build the llama.cpp xcframeworks once
ssh mac 'cd ~/Developer/dvai-bridge && bash scripts/mac-side-prepare-xcframework.sh'
```

## Web / JavaScript

### `web-react` — React + Vite + Transformers.js (browser, MSW)

What it shows: a React app whose chat UI talks to LangChain
`ChatOpenAI` pointed at the local MSW endpoint. Default backend is
Transformers.js; pluggable to WebLLM.

```bash
pnpm --filter web-react dev          # Vite dev server with HMR
# → open http://localhost:5173, click the prompt, watch tokens stream.
```

Verify: tokens appear in the response panel within ~5s after the model
downloads (~500 MB on first run, cached afterwards).

Adapt: replace `transformersModelId` in `src/App.tsx` to swap models;
swap `@langchain/openai` for the official `openai` package if you
prefer.

### `web-vanilla-cdn` — single HTML page, no bundler (browser, MSW)

What it shows: a `<script type="module">` tag pulls
`@dvai-bridge/vanilla` from a CDN, initializes the SDK, and calls
`fetch()` against the local MSW endpoint.

```bash
( cd examples/web-vanilla-cdn && python -m http.server 8000 )
# → open http://localhost:8000
bash examples/web-vanilla-cdn/smoke.sh   # static smoke (no model load)
```

Adapt: edit `index.html` directly — there's no build step.

### `node-langchain` — Node + Transformers.js + LangChain

What it shows: `dvai-bridge` running in plain Node, LangChain's
`ChatOpenAI.stream()` calling `http://127.0.0.1:38883/v1`.

```bash
pnpm --filter node-langchain start
# First run downloads the model into the HuggingFace cache.
```

Verify: streaming completion tokens print to the terminal.

Adapt: change `modelId` in `index.js`; change the LangChain prompt /
chain configuration to fit your app.

### `node-llama-cpp` — Node + native llama.cpp + LangChain

What it shows: `dvai-bridge` with `backend: "native"`, loading a GGUF
checkpoint via `node-llama-cpp`'s NAPI bindings.

```bash
pnpm --filter node-llama-cpp start
# First run downloads ~800 MB GGUF.
bash examples/node-llama-cpp/smoke.sh    # gated by SMOKE_MODEL_URL / SMOKE_MODEL_SHA256
```

Verify: token-rate roughly matches your CPU / GPU's tok/s ceiling.

Adapt: any GGUF that `llama.cpp` loads will work; swap the URL +
SHA-256 in `index.js`.

## iOS native

All iOS examples open with `open Package.swift`. Pick `iPhone 16` as
the run destination.

| Example | Backend | Model | Open |
| --- | --- | --- | --- |
| `ios-llama/` | llama.cpp | Llama-3.2-1B-Instruct Q4_K_M (~800 MB) | `cd examples/ios-llama && open Package.swift` |
| `ios-foundation/` | Apple Foundation Models | (Apple-managed) | `cd examples/ios-foundation && open Package.swift` |
| `ios-coreml/` | CoreML | finnvoorhees/coreml-Llama-3.2-1B-Instruct-4bit | `cd examples/ios-coreml && open Package.swift` |
| `ios-mlx/` | MLX | mlx-community/Llama-3.2-3B-Instruct-4bit | `cd examples/ios-mlx && open Package.swift` |

Build all four headlessly from a Windows / Linux host:

```bash
ssh mac 'cd ~/Developer/dvai-bridge && bash scripts/mac-side-build-examples.sh build'
```

Smoke any one in CI:

```bash
bash examples/ios-llama/smoke.sh
# On Mac: runs xcodebuild test asserting /v1/chat/completions returns non-empty.
# Off Mac: prints skip and exits 0.
```

Verify (after running on the simulator): tap **Load + Ask**, watch
the status label go through Download → Load → Bind, see tokens
stream into the scroll view.

Adapt: edit `Sources/<App>/<App>.swift` — change `modelUrl`,
`modelSha256`, or swap the OpenAI SDK for any other (the URL is
`bound.baseUrl`).

## Android native

All Android examples build with Gradle and consume the workspace AAR
from `mavenLocal()`.

| Example | Backend | Model |
| --- | --- | --- |
| `android-llama/` | llama.cpp | Llama-3.2-1B-Instruct Q4_K_M (~770 MB) |
| `android-mediapipe/` | MediaPipe LLM | Gemma-2-2B-IT `.task` (~1.3 GB) |
| `android-litert/` | LiteRT | `litert-community/Llama-3.2-1B-Instruct.tflite` (~1.0 GB) |

```bash
# Publish the AAR (one-time, after SDK source changes):
pwsh scripts/android-publish-local.ps1

# Build + smoke one example:
cd examples/android-llama && bash smoke.sh
# Runs JVM tests; connectedAndroidTest auto-skips when no device.
```

Run interactively:

```bash
cd examples/android-llama
./gradlew :app:installDebug && adb shell am start -n co.deepvoiceai.examples.androidllama/.MainActivity
```

Verify: tap Load + Ask, watch the Compose UI update through the
states, tokens render in the text view.

Adapt: edit `MainActivity.kt` — change `modelUrl` / `modelSha256`,
swap `aallam/openai-kotlin` for any other OpenAI client (pointed at
`bound.baseUrl`).

## React Native

### `react-native-app` — backend selector, all six native backends

What it shows: one screen, dropdown to pick a backend, supply
`modelPath`, call `DVAIBridge.start(...)`, then stream a chat
completion via the official `openai` npm SDK.

Run on Android (any host):

```bash
pnpm --filter react-native-app android
```

Run on iOS (Mac only):

```bash
pnpm install --ignore-scripts
cd examples/react-native-app/ios && bundle install && bundle exec pod install
cd .. && pnpm --filter react-native-app ios
```

Smoke:

```bash
bash examples/react-native-app/smoke.sh
# Typecheck + Metro bundle. RUN_ANDROID_BUILD=1 opts into the Gradle build.
```

Verify: the in-app log panel prints `licenseStatus.kind` and the
bound `baseUrl`; the response area streams tokens.

Adapt: edit `App.tsx` — backend dropdown values map to native enum
cases; the model-path text input feeds into `StartOptions`.

## Flutter

### `flutter-app` — backend dropdown, streaming via `dart:io` HttpClient

What it shows: a single `StreamBuilder<DVAIBridgeState>` driving the
UI; the user picks a backend, then `DVAIBridge.instance.start(...)`
boots the embedded server.

```bash
cd examples/flutter-app
flutter pub get
flutter run                # picks the connected device / simulator
bash smoke.sh              # pub get + pigeon regen + analyze + test
```

Verify: the dropdown disables platform-mismatched backends in-place;
selecting `mlx` on Android shows a `DVAIBridgeError(backendUnavailable)`.

Adapt: edit `lib/main.dart` — swap the backend defaults or the
prompt template.

## .NET

| Example | Type | Backend | Host |
| --- | --- | --- | --- |
| `dotnet-maui/` | MAUI single-project | Auto / Llama / Foundation / CoreML / MLX / MediaPipe / LiteRT | Android any; iOS / Catalyst Mac-only |
| `dotnet-desktop-llama/` | Console + Avalonia | llama.cpp via `DVAIBridge.Desktop` | Win / Mac / Linux |
| `dotnet-desktop-onnx/` | Console + Avalonia | ONNX Runtime GenAI via `DVAIBridge.OnnxRuntime` | any desktop |
| `dotnet-desktop-mlnet/` | Console only | ML.NET `OnnxScoringEstimator` | any desktop |

Build + smoke any one:

```bash
cd examples/dotnet-desktop-llama && bash smoke.sh
# Wiring-only verification; no model required.
```

Run interactively:

```bash
cd examples/dotnet-desktop-llama
dotnet build -c Release
dotnet run -c Release             # UI mode (Avalonia)
DVAI_HEADLESS=1 DVAI_MODEL_PATH=/path/to/model.gguf dotnet run -c Release
```

Verify (UI mode): the Avalonia window shows the bound base URL; click
**Send**, watch the streaming completion fill the text panel.

Adapt: each `.csproj` `<ProjectReference>` resolves into
`packages/dvai-bridge-dotnet/`; change the model path or backend
selector in `Program.cs`.

## Capacitor

### `capacitor-mobile` — hybrid web bundle + native llama.cpp

What it shows: a single HTML page in `www/` calls
`DVAIBridge.start({ backend: "llama", modelPath })` from the webview;
the chat input streams a completion via `fetch()` SSE.

```bash
# Web bundle:
pnpm --filter capacitor-mobile build

# One-time per platform:
pnpm --filter capacitor-mobile exec cap add android       # any host
pnpm --filter capacitor-mobile exec cap add ios           # Mac only

# Sync after every change to www/ or to a workspace plugin:
pnpm --filter capacitor-mobile exec cap sync android
ssh mac 'cd ~/Developer/dvai-bridge/examples/capacitor-mobile && \
  pnpm exec cap sync ios && cd ios/App && pod install'

# Run:
pnpm --filter capacitor-mobile exec cap run android
ssh mac '... cap run ios'
```

Smoke:

```bash
bash examples/capacitor-mobile/smoke.sh
# Builds the web bundle and runs `cap doctor`. No device required.
```

Verify: the webview loads, the chat textarea accepts a prompt, the
response area streams tokens.

Adapt: `www/index.html` is a plain HTML page — edit it directly. The
`scripts/build-www.mjs` esbuild runner picks up the changes.

## CI smoke matrix

Every example has a `smoke.sh` that:

1. Skips cleanly when its host-OS / hardware requirement isn't met.
2. Runs a wiring-only test on supported hosts (typecheck, bundle,
   `dotnet build`, Gradle JVM tests, `xcodebuild test` against a
   wiring assertion).
3. Optionally exercises a real model when a `SMOKE_MODEL_URL` /
   `SMOKE_MODEL_PATH` env var is provided.

```bash
# Run every smoke that the current host supports:
for ex in examples/*/smoke.sh; do
  echo "=== $ex ==="
  bash "$ex"
done
```

The full per-(SDK × backend) matrix with host requirements is in
[`examples/MATRIX.md`](https://github.com/Westenets/dvai-bridge/blob/main/examples/MATRIX.md).

## See also

- [Getting started](./getting-started) — the human-readable quickstart.
- [License setup](./license/) — what to add before shipping any of
  these to production.
- Per-SDK guide: [iOS](./ios-native-sdk),
  [Android](./android-native-sdk), [React Native](./react-native-sdk),
  [Flutter](./flutter-sdk), [.NET](./dotnet-sdk).
