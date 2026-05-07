# flutter-app

Flutter 3.39+ example showing
[`dvai_bridge`](../../packages/dvai-bridge-flutter) (the workspace
plugin) with a backend dropdown that covers all delegated backends:
Llama, Foundation, CoreML, MLX, MediaPipe, LiteRT.

The screen is a single `StreamBuilder<DVAIBridgeState>` listening to
`DVAIBridge.instance.stateStream`, plus a `dart:io` `HttpClient` that
streams the chat completion via SSE.

## What it shows

- One screen with a backend dropdown — items that don't run on the
  current platform are disabled in-place.
- `DVAIBridge.instance.start(StartOptions(...))` boots the embedded
  server. Backend availability is enforced by the plugin: selecting
  `mlx` on Android throws `DVAIBridgeError(backendUnavailable)`.
- `dart:io` `HttpClient` performs the streaming chat completion against
  `${BoundServer.baseUrl}/chat/completions`.

## Prereqs

- Flutter >= 3.39 with Dart >= 3.7 (CI exercises 3.41.x).
- For iOS: macOS + Xcode 16+; develop over `ssh mac` if your laptop is
  Windows.
- For Android: any host with the Android SDK / NDK r27+ + JDK 21.

## Run

```bash
# from `examples/flutter-app/`:
flutter pub get
flutter run            # picks the connected device / running simulator
```

The path-dep in `pubspec.yaml` resolves to the workspace plugin at
`packages/dvai-bridge-flutter/`, so any source change to the plugin is
visible after `flutter pub get` (no publish step needed).

## iOS notes

If you select `mlx` or `foundation` on Flutter, the default CocoaPods
build path can't link them — see the
[Flutter SDK guide](../../docs/guide/flutter-sdk.md) for the
`pod 'DVAIBridge', :path => ...` workaround.

## Provide a model file

Drop in a `.gguf` (Llama), `.task` (MediaPipe), `.tflite` (LiteRT),
`.mlpackage` (CoreML), or use a HuggingFace id (MLX). The Foundation
backend is zero-download — leave `modelPath` empty and pick `Foundation`
on iOS 26+.

For real distribution, use `DVAIBridge.instance.downloadModel(...)` from
the plugin — see the SDK guide for the resumable, sha256-verified
helper.

## Smoke test

```bash
bash examples/flutter-app/smoke.sh
```

Runs `flutter pub get`, regenerates Pigeon bindings on the workspace
plugin, then `flutter analyze` and `flutter test`. Real device builds
(`flutter run`) require the matching toolchain on the host.

## Files

| Path | Purpose |
|---|---|
| `lib/main.dart` | Single screen with backend dropdown, prompt, streaming output. |
| `pubspec.yaml` | Path-dep on `../../packages/dvai-bridge-flutter`. |
| `test/widget_test.dart` | Widget-level smoke covering the static surface. |
| `smoke.sh` | `pub get` + Pigeon regen + analyze + test. |
