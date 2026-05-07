# `examples/ios-foundation` — iOS native, Foundation Models backend

A minimum-viable SwiftUI app that boots `dvai-bridge` against Apple
Foundation Models — the on-device LLM Apple Intelligence ships with
iOS 26+. **No model download:** the OS manages the model.

## What it shows

- One-line bridge boot with no `modelPath`:
  `DVAIBridge.shared.start(.init(backend: .foundation))`.
- Streaming chat completions through the [MacPaw OpenAI
  SDK][macpaw] against `BoundServer.baseUrl`.
- Runtime gating: the UI shows a clear "requires iOS 26+" message on
  older simulators / devices.

[macpaw]: https://github.com/MacPaw/OpenAI

## Prereqs

- macOS host with **Xcode 16+** installed (Xcode 26 recommended for
  the iOS 26 SDK).
- **iOS 26+ simulator or device** at runtime — required for Apple
  Foundation Models. The package's link-time floor is iOS 18.1, so
  the app installs on older OSes but the backend will throw
  `backendUnavailable` when started.
- **SwiftPM-only.** This backend is not available under CocoaPods —
  see [CocoaPods asymmetries][podcaveat].

[podcaveat]: ../../docs/guide/ios-native-sdk.md#cocoapods-asymmetries

## Open in Xcode

```bash
cd examples/ios-foundation
open Package.swift
```

Pick an `iPhone 16 (iOS 26.0)` simulator if available; otherwise the
app will run but show the runtime-gating notice.

## What to expect on first run

1. Tap **Load + Ask**.
2. The bridge starts the Foundation Models backend instantly — there
   is no model download because Apple Intelligence already manages the
   on-device model.
3. The local server binds at `http://127.0.0.1:38883/v1`.
4. The MacPaw OpenAI SDK streams a chat completion; tokens appear in
   the scroll view as they arrive.

## No cache

The Foundation Models backend doesn't cache anything — the model is
shared across every Apple Intelligence-aware app on the device.

## Smoke test

```bash
bash smoke.sh
```

On Windows/Linux this prints a skip message and exits 0. On Mac, it
runs `xcodebuild test` against the `IOSFoundationApp` test target. The
test is gated to iOS 26+ at runtime (`XCTSkip` on older simulators);
pass `IOS_DEST="platform=iOS Simulator,name=iPhone 16,OS=26.0"` to
actually exercise the backend.

## Where the code points at the local server

In `Sources/IOSFoundationApp/IOSFoundationApp.swift`, look for the
`OpenAI(configuration: .init(...))` block — `host: 127.0.0.1`, `port`
from `BoundServer.port`, `basePath: "/v1"`, `scheme: "http"`. The SDK
treats it as a self-hosted OpenAI gateway.

## Why this example is so short

Foundation Models is the simplest backend to integrate from a
consumer's perspective: no GGUF, no `.mlpackage`, no HuggingFace ID.
The cost is iOS 26+ runtime requirement and SwiftPM-only distribution.

## See also

- [iOS Native SDK guide](../../docs/guide/ios-native-sdk.md)
- [examples/MATRIX.md](../MATRIX.md)
- [Phase 3F notes on the Foundation Models backend](../../CHANGELOG.md)
