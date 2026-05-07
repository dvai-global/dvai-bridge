# capacitor-mobile

Hybrid (iOS + Android) example app showing how to drop
[`@dvai-bridge/capacitor`](../../packages/dvai-bridge-capacitor) plus the
[`capacitor-llama`](../../packages/dvai-bridge-capacitor-llama) backend
plugin into a Capacitor 7 app, boot the embedded HTTP server from the
WebView, and stream an OpenAI-compatible chat completion via `fetch`.

## What it shows

- Single HTML page with a model-path input, prompt textarea, and a
  streaming response area.
- `DVAIBridge.start({ backend: 'llama', modelPath })` boots native
  llama.cpp and the embedded HTTP server bound to `127.0.0.1`.
- `fetch(${baseUrl}/chat/completions, { stream: true })` decodes
  Server-Sent Events inline — no SDK, no LangChain, just web platform.

## Prereqs

- Node 20+ and pnpm (run `pnpm install` at the repo root once).
- For iOS: macOS with Xcode 16+ (use the Mac mirror via `ssh mac` if you
  develop on Windows).
- For Android: JDK 21 + Android SDK with NDK r27+ on any host.

## Build the web bundle

```bash
pnpm --filter capacitor-mobile build
```

That runs `scripts/build-www.mjs`, which uses esbuild to inline
`@dvai-bridge/capacitor` into `www/main.js` and copies the HTML / CSS.

## Add native projects (one-time)

Capacitor's `cap add` writes the native project shells into this
directory. Run each platform on the host that supports it:

```bash
# Android (any host with the Android SDK):
pnpm --filter capacitor-mobile exec cap add android

# iOS (Mac only — over `ssh mac` if you develop on Windows):
pnpm --filter capacitor-mobile exec cap add ios
```

## Sync the plugins

After every change to `www/` or to a workspace plugin, run `cap sync`
on the platform you want to update:

```bash
# Android:
pnpm --filter capacitor-mobile cap:sync:android

# iOS (Mac):
pnpm --filter capacitor-mobile cap:sync:ios
```

`cap sync` does two things:

- Updates `www/` inside the native project bundles.
- Re-registers the workspace plugins (`@dvai-bridge/capacitor`,
  `@dvai-bridge/capacitor-llama`) — Gradle on Android, Pods / SwiftPM on
  iOS.

## Run on a device / simulator

```bash
# Android:
pnpm --filter capacitor-mobile exec cap run android

# iOS (Mac):
pnpm --filter capacitor-mobile exec cap run ios
```

## Provide a model file

`DVAIBridge.start()` needs a path to a `.gguf` file already on disk. Two
options:

1. **Side-load** a small GGUF (e.g. Llama-3.2-1B-Instruct Q4_K_M) into
   the app's documents directory and paste the path into the input.
2. **Download in-app** with `DVAIBridge.downloadModel(...)` — see
   [`docs/guide/quickstart-capacitor.md`](../../docs/guide/quickstart-capacitor.md)
   for the resumable, sha256-verified helper.

Once the model is on disk, the placeholder path in `src/index.html`
shows the conventional Android documents-dir layout
(`/data/user/0/<appId>/files/dvai-models/...`).

## Smoke test

`bash examples/capacitor-mobile/smoke.sh` verifies the web bundle
builds and that `@dvai-bridge/capacitor` can be resolved from the
workspace. It does NOT run a simulator — that is delegated to
`scripts/demos/capacitor.yaml` which the marketing recorder drives.

## Files

| Path | Purpose |
|---|---|
| `src/index.html` | The single page rendered in the WebView. |
| `src/main.js` | Imports `@dvai-bridge/capacitor`, drives start/stop/stream. |
| `src/styles.css` | Minimal dark-mode CSS. |
| `scripts/build-www.mjs` | esbuild bundler for the web tier. |
| `capacitor.config.ts` | App id, app name, `webDir: "www"`. |
| `smoke.sh` | Build + bundle-resolution check. |
