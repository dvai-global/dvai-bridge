# Examples

Runnable examples for DVAI-Bridge across every supported stack. Each one
is self-contained — the JavaScript examples live in this workspace; the
native examples are thin starter projects you can copy into your own
environment.

## JavaScript / TypeScript

Each JS example is a standalone workspace package — no extra install step
beyond `pnpm install` at the repo root.

| Example | Platform | Backend | Transport | What it shows |
|---|---|---|---|---|
| `web-react` | Browser | WebLLM / Transformers.js | MSW | React + Vite + `@dvai-bridge/react` |
| `node-langchain` | Node | Transformers.js | HTTP | LangChain + OpenAI SDK against local loopback |
| `electron-desktop` | Electron | Native llama.cpp (CUDA / Metal / Vulkan) | HTTP | Desktop app with GPU-accelerated inference in the main process |
| `capacitor-mobile` | Capacitor (iOS + Android) | Native llama.cpp | HTTP | Hybrid mobile app calling the embedded server from a webview |
| `nextjs-app` | Browser + Node (Next.js) | Transformers.js | MSW (client) / HTTP (API routes) | Same agent code on server and client |
| `vanilla-cdn` | Browser (no build step) | WebLLM | MSW | `<script>` tag via jsDelivr |

### Run a JS example

```bash
pnpm install
pnpm --filter <example-name> start   # or `dev`, `build` — check the example's package.json
```

## iOS (Swift)

| Example | Shows |
|---|---|
| `ios-swift-basic` | Minimal iOS app using the `DVAIBridge` Swift Package and Apple's OpenAI SDK |
| `ios-swift-multimodal` | Vision-language model (LLaVA) via llama.cpp with Metal acceleration |

Open the `.xcodeproj` in Xcode, let SPM resolve dependencies, and run
on simulator or device.

## Android (Kotlin)

| Example | Shows |
|---|---|
| `android-kotlin-basic` | Minimal Android app using the `co.deepvoiceai:dvai-bridge` AAR + a community OpenAI Kotlin client |
| `android-kotlin-qnn` | QNN Hexagon acceleration on Snapdragon devices |

Open in Android Studio, let Gradle sync, and run on emulator or device.

## .NET desktop (C#)

| Example | Shows |
|---|---|
| `dotnet-wpf-basic` | WPF desktop app consuming the `DeepVoiceAI.DVAIBridge` NuGet package |
| `dotnet-winui-directml` | WinUI 3 app with DirectML acceleration on Windows |

Open the `.sln` in Visual Studio or run `dotnet run` in the example
directory.

## React Native / Flutter

Not currently shipped as dedicated examples — the frameworks consume the
iOS Swift Package and Android AAR directly through standard native-bridge
patterns. Dedicated React Native and Flutter example projects will land
when the wrapper packages ship.

---

## Contributing an example

Good examples:

- **Teach one thing clearly.** Streaming. Multimodal. Embeddings. Offline
  mode. Pick one focus.
- **Ship a complete project.** Not just a single source file — a full
  manifest (`package.json`, `Package.swift`, `build.gradle.kts`, `.csproj`),
  a focused `README.md`, and a clear `start` / `run` command.
- **Use the platform's idiomatic OpenAI SDK** — not a DVAI-specific
  API. The point is to show "standard agent code, local server."
- **Work on first-run with no extra setup.** Model downloads are OK
  (flag them in the README); system-wide installs are not.

Open a PR — the core team reviews examples like any other contribution.
