# Examples

Runnable examples for DVAI-Bridge. This directory ships the JavaScript
examples as workspace packages — they install with `pnpm install` at the
repo root and have no extra setup step.

Native-platform examples (iOS, Android, React Native, Flutter, .NET) are
**not yet** in this directory; the per-SDK quickstarts in
[`docs/guide/`](../docs/guide/) are the current entry point for those
platforms while the matrix of (SDK × backend) example apps is built out
in Phase 2 of the post-v2.4 roadmap.

## JavaScript / TypeScript (shipped)

| Example | Platform | Backend | Transport | What it shows |
|---|---|---|---|---|
| `web-react` | Browser | Transformers.js (default; pluggable to WebLLM) | MSW | React + Vite + LangChain `ChatOpenAI` against the local mocked endpoint |
| `node-langchain` | Node | Transformers.js | HTTP loopback | LangChain `ChatOpenAI.stream()` against `dvai.baseUrl` |

### Run

```bash
# From repo root, one-time:
pnpm install --ignore-scripts

# web-react (in the browser):
pnpm --filter web-react dev          # Vite dev server with HMR

# node-langchain (in the terminal):
pnpm --filter node-langchain start   # downloads the model on first run
```

The first run of either example downloads a small model (~500 MB for
Transformers.js Gemma 3n; cached on subsequent runs).

## Other platforms

For now, see:

- [iOS native quickstart](../docs/guide/ios-native-sdk.md)
- [Android native quickstart](../docs/guide/android-native-sdk.md)
- [React Native quickstart](../docs/guide/react-native-sdk.md)
- [Flutter quickstart](../docs/guide/flutter-sdk.md)
- [.NET quickstart](../docs/guide/dotnet-sdk.md)

Each guide contains a copy-pasteable minimum viable app that hits the
same OpenAI-compatible local endpoint. The full per-(SDK × backend)
example matrix is on the post-v2.4 roadmap.

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
