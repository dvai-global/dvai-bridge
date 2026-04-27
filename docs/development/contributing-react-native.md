# Contributing: React Native SDK

This page covers the local build + test loop for contributors working on
the React Native slice. For end-user docs see
[react-native-sdk.md](/guide/react-native-sdk).

The RN package is a **TurboModule** that wraps the iOS and Android
native SDKs. There is no JS-side state machine — the JS layer is a thin
`NativeModules` (TurboModule) wrapper, and all state lives in the
per-platform `DVAIBridge` shared instance on the native side. This keeps
the RN package in lockstep with the Swift / Kotlin handlers and avoids a
third place where bugs can hide.

## Prerequisites

- **Node 25+** (the package's `engines.node` floor is `>=22`, but the
  monorepo CI matrix runs Node 25 — match it locally to avoid drift).
- **pnpm** — the workspace tool. The repo root has the lockfile.
- **React Native 0.77+** for the example app and any consumer test
  harness. The package's `peerDependencies` enforce this.
- **iOS toolchain** — Xcode 16+, CocoaPods, iOS 18.5 simulator. See
  [contributing-ios.md](./contributing-ios.md).
- **Android toolchain** — JDK 23, Android SDK 36. See
  [contributing-android.md](./contributing-android.md).
- **`react-native-builder-bob`** — installed as a devDep; runs
  automatically via `pnpm build`.

## Build + test loop

```bash
cd packages/dvai-bridge-react-native

# Install + build the published JS / TS output (commonjs + module + types).
pnpm install
pnpm build                                # equivalent to `bob build`

# Type-check + Jest (testRegex covers handler-parity TurboModule mocks).
pnpm typecheck
pnpm test
```

### TurboModule codegen

Codegen is wired through React Native's standard `codegenConfig` block
in `package.json` (spec name `RNDVAIBridgeSpec`, Java package
`co.deepvoiceai.bridge.rn`). RN's CLI regenerates the spec on
`pod install` (iOS) and during the Android Gradle build, so there is
**no separate `pnpm codegen` script**.

If you need to regenerate manually after editing `src/NativeDVAIBridge.ts`
or another spec file, the path is:

- **iOS:** `cd example/ios && pod install` — `RCT-Folly`'s post-install
  step runs codegen into `build/generated/ios/`.
- **Android:** `cd example/android && ./gradlew generateCodegenArtifactsFromSchema`.

<!-- TODO: confirm exact regen command path once Phase 3H Task 4 (RN
example app + smoke) lands; the example/ folder may add a top-level
pnpm script that wraps both. -->

### Example app workflow

The example app lives under `packages/dvai-bridge-react-native/example/`
(if not yet present, this is being added in Phase 3H Task 4).

```bash
cd packages/dvai-bridge-react-native/example
pnpm install

# iOS simulator:
cd ios && pod install && cd ..
pnpm ios

# Android emulator (with one running):
pnpm android
```

## Common breakage modes

- **TurboModule registration error on Android** — codegen output is
  stale after a spec edit. Run
  `cd example/android && ./gradlew clean generateCodegenArtifactsFromSchema`.
- **iOS pod install picks up an old DVAIBridgeNative.podspec** —
  `pod cache clean DVAIBridgeNative && pod install`. Same advice as
  [contributing-ios.md](./contributing-ios.md).
- **Metro stale cache after a TS spec rename** — `pnpm start --reset-cache`
  in the example app.
- **`builder-bob` complains about missing `lib/`** — `pnpm clean &&
  pnpm build`. The `prepack` script also runs `bob build`.
- **JS-side state expectations** — if you find yourself reaching for a
  `useReducer` to mirror native lifecycle, stop. State lives on the
  native side; the JS layer should only forward calls and surface
  events. See the rationale at the top of this page.

## Related

- [React Native SDK guide](/guide/react-native-sdk) — user-facing API.
- [contributing-ios.md](./contributing-ios.md) — the iOS half of the
  TurboModule's native build.
- [contributing-android.md](./contributing-android.md) — the Android
  half.
- [Handler parity](./handler-parity.md) — TurboModule changes must
  stay aligned with the underlying Swift / Kotlin handlers.
