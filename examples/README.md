# Examples

Runnable examples for DVAI-Bridge. This directory ships the JavaScript
examples as workspace packages — they install with `pnpm install` at the
repo root and have no extra setup step.

Native-platform examples are landing through Phase 2 of the post-v2.4
roadmap. iOS native is shipped (see below); Android, React Native,
Flutter, and .NET are tracked in [`MATRIX.md`](./MATRIX.md) and ship
incrementally — until then, the per-SDK quickstarts in
[`docs/guide/`](../docs/guide/) remain the entry point for those
platforms.

## JavaScript / TypeScript (shipped)

| Example | Platform | Backend | Transport | What it shows |
|---|---|---|---|---|
| [`web-react`](./web-react/) | Browser | Transformers.js (default; pluggable to WebLLM) | MSW | React + Vite + LangChain `ChatOpenAI` against the local mocked endpoint |
| [`web-vanilla-cdn`](./web-vanilla-cdn/) | Browser | Transformers.js | MSW | Single `index.html` + `<script>` tag — no bundler, no build step |
| [`node-langchain`](./node-langchain/) | Node | Transformers.js | HTTP loopback | LangChain `ChatOpenAI.stream()` against `dvai.baseUrl` |
| [`node-llama-cpp`](./node-llama-cpp/) | Node | llama.cpp (`node-llama-cpp`) | HTTP loopback | Native GGUF inference via `backend: "native"` + LangChain |

The full per-(SDK × backend) matrix tracking ship/planned status lives
in [`MATRIX.md`](./MATRIX.md).

### Run

```bash
# From repo root, one-time:
pnpm install --ignore-scripts

# web-react (in the browser):
pnpm --filter web-react dev          # Vite dev server with HMR

# web-vanilla-cdn (in the browser, no build):
( cd examples/web-vanilla-cdn && python -m http.server 8000 )

# node-langchain (in the terminal):
pnpm --filter node-langchain start   # downloads the model on first run

# node-llama-cpp (in the terminal):
pnpm --filter node-llama-cpp start   # downloads ~800 MB GGUF on first run
```

The first run of any example downloads a model (~500 MB for the
Transformers.js examples, ~800 MB for the GGUF used by node-llama-cpp;
cached on subsequent runs).

## iOS native (shipped — Phase 2)

Four SwiftUI example apps, one per backend, that path-dep the
in-monorepo `packages/dvai-bridge-ios` SwiftPM package:

| Example | Backend | Model | Host requirements |
|---|---|---|---|
| [`ios-llama/`](./ios-llama/) | llama.cpp | bartowski/Llama-3.2-1B-Instruct-GGUF Q4_K_M (~800 MB) | Mac + Xcode 16+ |
| [`ios-foundation/`](./ios-foundation/) | Apple Foundation Models | (managed by Apple Intelligence) | Mac + iOS 26+ at runtime |
| [`ios-coreml/`](./ios-coreml/) | CoreML / ANE | finnvoorhees/coreml-Llama-3.2-1B-Instruct-4bit | Mac (experimental — see README) |
| [`ios-mlx/`](./ios-mlx/) | MLX | mlx-community/Llama-3.2-3B-Instruct-4bit (~1.8 GB) | Apple Silicon Mac |

Each opens with `open Package.swift` in Xcode and runs on the
iPhone 16 simulator. Build all four in one Mac SSH session:

```bash
ssh mac 'cd ~/Developer/dvai-bridge && bash scripts/mac-side-build-examples.sh build'
```

## Other platforms

For now, see:

- [Android native quickstart](../docs/guide/android-native-sdk.md)
- [React Native quickstart](../docs/guide/react-native-sdk.md)
- [Flutter quickstart](../docs/guide/flutter-sdk.md)
- [.NET quickstart](../docs/guide/dotnet-sdk.md)

Each guide contains a copy-pasteable minimum viable app that hits the
same OpenAI-compatible local endpoint. The full per-(SDK × backend)
example matrix is in [`MATRIX.md`](./MATRIX.md).

---

## Contributing an example

Good examples:

- **Teach one thing clearly.** Streaming. Multimodal. Embeddings. Offline
  mode. Pick one focus.
- **Ship a complete project.** Not just a single source file — a full
  manifest (`package.json`, `Package.swift`, `build.gradle.kts`,
  `pubspec.yaml`, `.csproj`), a focused `README.md`, and a clear
  `start` / `run` command.
- **Use the platform's idiomatic OpenAI SDK** — not a DVAI-specific
  API. The point is to show "standard agent code, local server."
- **Work on first-run with no extra setup beyond model download.**
  Flag the download in the README; system-wide installs are not OK.

Open a PR — the core team reviews examples like any other contribution.
See [`CONTRIBUTING.md`](../CONTRIBUTING.md) for the PR flow.
