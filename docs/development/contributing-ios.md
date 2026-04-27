# Contributing: iOS Native SDK

This page covers the local build + test loop for contributors working on
the iOS slice. For end-user docs see
[ios-native-sdk.md](/guide/ios-native-sdk).

iOS work is **Mac-only** — `xcodebuild`, the iOS Simulator, and
CocoaPods all require macOS. If your dev box is Windows or Linux, see
[Mac remote builds](./mac-remote-builds.md) for the SSH wrapper that
shells everything out to a remote Mac.

## Prerequisites

- **Xcode 16+** (Xcode 26 on the CI runner). Install via the App Store,
  open it once to accept the license, and let it pull the iOS 18.5 SDK +
  Metal toolchain.
- **iOS 18.5 simulator runtime** with an `iPhone 16` device, matching
  the destination string used by both local scripts and CI.
- **CocoaPods** — required for the `pod lib lint` pass and for
  Capacitor / RN consumers that resolve the pod. Recent macOS releases
  ship a working Ruby; install with `sudo gem install cocoapods` if
  you don't already have `pod` on `PATH`.
- **System Ruby** is fine for `pod` invocations. No `rbenv` / `rvm`
  required.

## Build + test loop

The Swift Package is the source of truth — `xcodebuild` against the
package scheme runs the same target graph that SwiftPM consumers see.

```bash
cd packages/dvai-bridge-ios

# Run the umbrella test scheme on the iOS 18.5 / iPhone 16 simulator.
xcodebuild test \
  -scheme DVAIBridge-Package \
  -destination "platform=iOS Simulator,name=iPhone 16,OS=18.5"

# Pure-logic targets that don't need a simulator can also use:
swift test
```

Validate the podspec before publishing or whenever you touch
`DVAIBridge.podspec`, the prepare-command, or any source-file glob:

```bash
pod lib lint DVAIBridge.podspec --allow-warnings
```

`--allow-warnings` is required because the vendored
`swift-transformers` copy under `Vendor/` emits a handful of
deprecation warnings that we accept knowingly (they're upstream and
out of our control).

## Common breakage modes

- **Stale Pods cache** — old vendored sources from a previous
  `prepare_command` run linger in `~/Library/Caches/CocoaPods/`. Clear
  with `pod cache clean --all && pod cache clean DVAIBridge`.
- **Simulator OOM during multi-method test runs** — the per-test
  coverage workflow now invokes `xcodebuild test-without-building` per
  method (see commit `aadcd1f`). Locally, kill stale `Simulator.app`
  and `CoreSimulator` processes between runs:
  `pkill -f CoreSimulator; pkill -f "iOS Simulator"`.
- **"Result bundle path already exists"** — a previous run was killed
  mid-flight and left `build/test-results.xcresult`. Delete it:
  `rm -rf packages/dvai-bridge-ios/build/`.
- **Code signing** — tests run with automatic signing on the simulator
  destination. If you see a signing prompt, you've accidentally selected
  a real-device destination; switch back to a simulator.
- **Vendored imports out of sync** — `DVAILlamaCore` and friends are
  copied into `Sources/_external/` by the podspec's `prepare_command`.
  If you edit a sibling `*-core` package, re-run `pod install` (or
  `pod lib lint`) so the copies refresh.

## Related

- [iOS Native SDK guide](/guide/ios-native-sdk) — user-facing API.
- [Mac remote builds](./mac-remote-builds.md) — Windows / Linux dev
  boxes that round-trip to a Mac for `xcodebuild`.
- [Testing](./testing.md) — full layer-by-layer test guide, including
  the iOS XCTest layer (Layer 2).
- [Handler parity](./handler-parity.md) — why the Swift handlers must
  stay byte-for-byte aligned with the Kotlin and TS suites.
