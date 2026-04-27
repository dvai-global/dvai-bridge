# Phase 3E — React Native Module Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to execute this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up `packages/dvai-bridge-react-native/` — npm package `@dvai-bridge/react-native`. A TurboModule that wraps the v2.1 iOS DVAIBridge SDK + v2.1 Android DVAIBridge SDK behind a shared TS API.

**Architecture:** TS facade (`DVAIBridge` object + `useDVAIBridgeState` hook) → TurboModule spec (`NativeDVAIBridge`) → Swift bridge (calls `DVAIBridge.shared`) on iOS / Kotlin bridge (calls `co.deepvoiceai.bridge.DVAIBridge`) on Android. Reactive state surfaced via `NativeEventEmitter` over `Combine` / `Flow` events.

**Tech Stack:** TypeScript 5.7+ / React Native 0.77+ (Bridgeless ON) / Swift 5.9+ / Kotlin 2.x / `react-native-builder-bob` 0.40.x for build. iOS minimum: 15.1 (RN 0.77 floor). Android minimum: 24 (matches dvai-bridge-android umbrella's `minSdk`).

**Spec:** [`docs/superpowers/specs/2026-04-27-phase3e-react-native-module-design.md`](../specs/2026-04-27-phase3e-react-native-module-design.md)

**Resolution of spec open questions (decided here, applied throughout):**

1. **`react-native-builder-bob` version**: pin to latest stable at task start (verify on npm at scaffold time).
2. **iOS pod dep**: CocoaPods `DVAIBridge.podspec` (matches what RN's `pod install` flow expects). Document the MLX-under-CocoaPods caveat. RN consumers wanting MLX use SPM via `:path` in their Podfile (Phase 3F-onward problem; not 3E's).
3. **Minimum RN**: 0.77+ (Bridgeless ON, TurboModule-only). Document in the README. Capacitor stays the path for older RN.
4. **Codegen output**: gitignored. Generated at `pod install` / Gradle sync — RN's standard flow.

**Phase boundaries:**

- **Tasks 1-3**: Package scaffold + TS public types + facade.
- **Tasks 4-6**: TurboModule spec + iOS bridge.
- **Tasks 7-9**: Android bridge + autolinking + ProgressEvent emitter.
- **Tasks 10-11**: React hook + tests (Jest mocks for the TS surface).
- **Tasks 12-13**: Docs + CI workflow.
- **Task 14**: Version bump (2.1.0 → 2.2.0) + CHANGELOG + tag v2.2.0.

**Apply Phase 3C/3D lessons up-front:**

1. **Mirror iOS DVAIBridge / Android DVAIBridge naming where practical**, but TS uses lowercase string-enum values (`"auto"`, `"llama"`) for JSON-friendly serialization.
2. **TurboModule codegen takes `object` for loose types** — TS facade does the strong-typing on the JS side.
3. **iOS pod via the existing `DVAIBridge.podspec`** — no new podspec at the iOS-bridge layer. Just declare a podspec with `s.dependency 'DVAIBridge'`.
4. **Android dep via `co.deepvoiceai:dvai-bridge:2.1.0`** through GitHub Packages Maven (the consumer's app needs the maven repo entry — document in the consumer guide).
5. **Always pin to LATEST** for RN, builder-bob, TS, Kotlin, Swift versions per the user's standing instruction.

---

## Task 1: Scaffold `dvai-bridge-react-native` package

**Files:**
- Create: `packages/dvai-bridge-react-native/package.json`
- Create: `packages/dvai-bridge-react-native/tsconfig.json`
- Create: `packages/dvai-bridge-react-native/tsconfig.build.json`
- Create: `packages/dvai-bridge-react-native/babel.config.js`
- Create: `packages/dvai-bridge-react-native/react-native.config.js`
- Create: `packages/dvai-bridge-react-native/.gitignore`
- Create: `packages/dvai-bridge-react-native/src/.gitkeep`
- Create: `packages/dvai-bridge-react-native/ios/.gitkeep`
- Create: `packages/dvai-bridge-react-native/android/.gitkeep`

- [ ] Verify latest stable for: `react-native`, `react-native-builder-bob`, `typescript`, `@types/react`, `@types/react-native`. Use those versions in `package.json`.
- [ ] `package.json`: `"name": "@dvai-bridge/react-native"`, `"version": "2.1.0"` (will be bumped by Task 14), `"main": "lib/commonjs/index.js"`, `"module": "lib/module/index.js"`, `"types": "lib/typescript/src/index.d.ts"`, `peerDependencies` on `react`, `react-native`, `peerDependenciesMeta` for both. Scripts: `"prepack": "bob build"`, `"clean": "del lib"`. `react-native-builder-bob` config under `"react-native-builder-bob"` key in package.json (commonjs + module + typescript targets).
- [ ] `tsconfig.json`: `target: "ES2020"`, `module: "ESNext"`, `moduleResolution: "node"`, `jsx: "react"`, `strict: true`, `skipLibCheck: true`. `tsconfig.build.json` extends with `noEmit: false` and the source dir.
- [ ] `babel.config.js`: presets `module:metro-react-native-babel-preset`.
- [ ] `react-native.config.js`: autolinking config from spec §4.2.
- [ ] `.gitignore`: `lib/`, `*.tgz`, `.tsbuildinfo`, codegen output dirs (`generated/`, `build/`, `Pods/`, `*.xcodeproj`).

**Acceptance:** `pnpm install` recognizes the new package; `pnpm -r run build` doesn't fail (the new package has nothing to build yet but `prepack` shouldn't blow up either — the script can be a no-op until we have source).

---

## Task 2: Public TS types

**Files:**
- Create: `packages/dvai-bridge-react-native/src/types.ts`
- Create: `packages/dvai-bridge-react-native/src/errors.ts`

- [ ] `types.ts`: `BackendKind` string enum (8 values per spec §3.4); `StartOptions` interface (modelPath, tokenizerPath, mmprojPath, contextSize, threads, gpuLayers, httpBasePort, httpMaxPortAttempts, corsOrigin, temperature, topP, topK, maxNewTokens, modelId — all optional except as required by the chosen backend); `BoundServer` interface (baseUrl, port, backend, modelId); `StatusInfo` interface (running, baseUrl?, port?, backend?, modelId?); `DownloadOptions` (url, sha256, destFilename); `DownloadResult` (path, sha256, sizeBytes); `ProgressEvent` discriminated union (`kind: "started" | "progress" | "completed" | "failed"`, plus payload fields).
- [ ] `errors.ts`: `DVAIBridgeError` class extending `Error`. `kind: "alreadyStarted" | "configurationInvalid" | "modelLoadFailed" | "backendUnavailable" | "backendError" | "checksumMismatch" | "downloadFailed"`. Stable error codes mirror iOS / Android.

**Acceptance:** `tsc --noEmit` passes against `src/types.ts` and `src/errors.ts`.

---

## Task 3: TS facade — `DVAIBridge` + `index.ts`

**Files:**
- Create: `packages/dvai-bridge-react-native/src/DVAIBridge.ts`
- Create: `packages/dvai-bridge-react-native/src/index.ts`

- [ ] `DVAIBridge.ts`: object literal with `start`, `stop`, `status`, `downloadModel`, `addProgressListener`, `removeProgressListener` methods. Each delegates to the TurboModule (Task 4) after platform-specific BackendKind validation (spec §3.4). `start` throws `DVAIBridgeError.backendUnavailable` for incompatible-platform backends before invoking native.
- [ ] `index.ts`: re-exports `DVAIBridge`, `BackendKind`, `StartOptions`, `BoundServer`, `StatusInfo`, `DownloadOptions`, `DownloadResult`, `ProgressEvent`, `DVAIBridgeError`, `useDVAIBridgeState` (Task 10).
- [ ] Add `Platform` from `react-native` for the TS-side validation.

**Acceptance:** `tsc --noEmit` passes; `react-native-builder-bob` build emits typed lib/ output (verify after Task 4 lands the TurboModule).

---

## Task 4: TurboModule spec — `NativeDVAIBridge.ts`

**Files:**
- Create: `packages/dvai-bridge-react-native/src/NativeDVAIBridge.ts`

- [ ] `NativeDVAIBridge.ts`: TurboModule spec per spec §3.3. Methods: `startBridge(opts: object): Promise<object>`, `stopBridge(): Promise<void>`, `status(): Promise<object>`, `downloadModel(opts: object): Promise<object>`, `addListener(name: string): void`, `removeListeners(count: number): void`. Module name: `"DVAIBridge"`.
- [ ] Update `package.json` to enable RN codegen for this spec (codegen config block).

**Acceptance:** `tsc --noEmit` passes; running `pod install` in a sample RN app generates the iOS Obj-C++ header/impl pair (verify in Task 6 when iOS bridge lands).

---

## Task 5: iOS podspec + bridging metadata

**Files:**
- Create: `packages/dvai-bridge-react-native/ios/DVAIBridgeNative.podspec`

- [ ] Podspec declares: `s.name = 'DVAIBridgeNative'`, `s.version = '2.1.0'`, `s.platform = :ios, '15.1'`, `s.swift_version = '5.9'`, `s.source_files = 'ios/*.{swift,mm,m,h}'`, `s.dependency 'DVAIBridge'` (the Phase 3C umbrella podspec), `s.dependency 'React-Core'`, `s.dependency 'React-RCTBlob'`. RN-managed flags via `install_modules_dependencies(s)` (the standard RN podspec helper).
- [ ] Document the MLX-under-CocoaPods caveat as a comment in the podspec.

**Acceptance:** `pod lib lint DVAIBridgeNative.podspec --allow-warnings` passes against an RN 0.77 sample's Podfile.

---

## Task 6: iOS bridge — Swift TurboModule impl

**Files:**
- Create: `packages/dvai-bridge-react-native/ios/DVAIBridgeNative.swift`
- Create: `packages/dvai-bridge-react-native/ios/DVAIBridgeNative.mm`
- Create: `packages/dvai-bridge-react-native/ios/DVAIBridgeNative.h`

- [ ] `DVAIBridgeNative.h`: declares the Obj-C `DVAIBridgeNative` class extending `RCTEventEmitter` and conforming to the codegenerated `NativeDVAIBridgeSpec` protocol.
- [ ] `DVAIBridgeNative.mm`: TurboModule registration using `RCT_EXPORT_MODULE("DVAIBridge")` macro.
- [ ] `DVAIBridgeNative.swift`: implements each method by translating NSDictionary opts to Swift types, calling `DVAIBridge.shared.start(...)`, returning the result back as NSDictionary. Throws bridged to `RCTPromiseRejectBlock` with the iOS error's `kind` string + localized message.
- [ ] Hook the iOS DVAIBridge progress publisher to `RCTEventEmitter.sendEvent(withName: "DVAIBridgeProgress", body: ...)`.

**Acceptance:** With a sample RN 0.77 app, building for iOS Simulator works; calling `DVAIBridge.start(...)` from JS lands at the Swift method without crash.

---

## Task 7: Android Gradle module + Kotlin bridge

**Files:**
- Create: `packages/dvai-bridge-react-native/android/build.gradle`
- Create: `packages/dvai-bridge-react-native/android/settings.gradle`
- Create: `packages/dvai-bridge-react-native/android/gradle.properties`
- Create: `packages/dvai-bridge-react-native/android/src/main/AndroidManifest.xml`
- Create: `packages/dvai-bridge-react-native/android/src/main/java/co/deepvoiceai/bridge/rn/DVAIBridgeNativeModule.kt`
- Create: `packages/dvai-bridge-react-native/android/src/main/java/co/deepvoiceai/bridge/rn/DVAIBridgePackage.kt`

- [ ] `build.gradle`: AGP 9.2.0, minSdk 24, compileSdk 36, JVM 17. Depends on `co.deepvoiceai:dvai-bridge:$dvaiBridgeVersion` via `mavenLocal() + GitHub Packages Maven`. RN-managed via `apply from: "$rootDir/../node_modules/react-native/jvm/main/runtime.gradle"` (or whatever the standard RN library Gradle setup is at the chosen RN version).
- [ ] `DVAIBridgeNativeModule.kt`: extends `ReactContextBaseJavaModule`, implements the codegen `NativeDVAIBridgeSpec`. Each method translates `ReadableMap` → Kotlin Map, calls `DVAIBridge.start(StartOptions(...))`, converts result back to `WritableMap`. Mutex-serialized to match the iOS model.
- [ ] Hook `DVAIBridge.progressFlow` collection to `getReactApplicationContext().getJSModule(RCTDeviceEventEmitter.class).emit("DVAIBridgeProgress", ...)`.
- [ ] `DVAIBridgePackage.kt`: registers the module via the standard `ReactPackage` interface.

**Acceptance:** Sample RN 0.77 Android app's `:app:assembleDebug` passes; calling `DVAIBridge.start(...)` from JS lands at the Kotlin method.

---

## Task 8: Autolinking config

**Files:**
- Update: `packages/dvai-bridge-react-native/react-native.config.js` (created in Task 1)

- [ ] Already declared in Task 1; verify against the chosen RN version's autolinking schema.

**Acceptance:** A consumer running `pod install` after `npm install @dvai-bridge/react-native` picks up the iOS pod automatically.

---

## Task 9: Progress event emitter wiring

This is partially in Tasks 6 + 7; this task is to verify both emit consistent event payloads.

- [ ] Both iOS and Android emit a JSON-serializable object on the `DVAIBridgeProgress` channel: `{ kind: "started" | "progress" | "completed" | "failed", phase: "start" | "stop" | "download", percent?: number, message?: string, error?: { kind: string, message: string } }`.
- [ ] iOS: tap `DVAIBridge.shared.progressPublisher` (Combine), map to NSDictionary, `sendEvent`.
- [ ] Android: `viewModelScope.launch { DVAIBridge.progressFlow.collect { event -> emit("DVAIBridgeProgress", toMap(event)) } }`. Lifecycle: cancel the collection on `invalidate()`.

**Acceptance:** A unit-style sanity test (Task 11) subscribes to the JS-side emitter and asserts the event payload shape.

---

## Task 10: React hook — `useDVAIBridgeState`

**Files:**
- Create: `packages/dvai-bridge-react-native/src/hooks/useDVAIBridgeState.ts`

- [ ] Implementation per spec §3.5. Subscribes to the JS-side EventEmitter, refetches `status()` on `started` / `completed` / `stop` events, returns the cached state object. Cleanup on unmount.

**Acceptance:** A small Jest test (Task 11) renders a tiny consumer component, dispatches a fake event, asserts the hook's state updates.

---

## Task 11: Jest tests for the TS facade + hook

**Files:**
- Create: `packages/dvai-bridge-react-native/src/__tests__/DVAIBridge.test.ts`
- Create: `packages/dvai-bridge-react-native/src/__tests__/useDVAIBridgeState.test.tsx`
- Create: `packages/dvai-bridge-react-native/jest.config.js`

- [ ] Mock `NativeDVAIBridge` via `jest.mock`. Test cases:
  - `start()` rejects iOS-only backend on Android (`backendUnavailable`).
  - `start()` rejects Android-only backend on iOS.
  - `start()` forwards opts and resolves the BoundServer shape.
  - `stop()` calls native and resolves void.
  - `addProgressListener` returns a removable subscription.
  - `useDVAIBridgeState` updates on `progress` / `completed` / `failed` events.

**Acceptance:** `npm test` runs all 6 tests green inside the package.

---

## Task 12: Docs — `react-native-sdk.md` + migration entry

**Files:**
- Create: `docs/guide/react-native-sdk.md`
- Update: `docs/migration/v1.6-to-v2.0.md` (append RN section)
- Update: `docs/.vitepress/config.ts` (sidebar add)

- [ ] Mirrors `ios-native-sdk.md` / `android-native-sdk.md` structure: install (npm + autolinking + iOS pod install + Android Gradle), Quickstart, BackendKind table + platform availability, `useDVAIBridgeState` hook, error reference, MLX-under-CocoaPods caveat, Bridgeless requirement.
- [ ] Migration: note that RN ≤ 0.73 consumers stay on Capacitor.

**Acceptance:** `pnpm run docs:dev` renders the new page; no broken links.

---

## Task 13: CI — RN module workflow

**Files:**
- Create: `.github/workflows/test-react-native.yml`

- [ ] Steps: checkout, Node setup, `pnpm install`, `pnpm -F @dvai-bridge/react-native run build`, `pnpm -F @dvai-bridge/react-native test`. Optionally a smoke job that does a sample RN 0.77 app's `pod install` + `xcodebuild -dry-run` + Android `assembleDebug` to verify autolinking.

**Acceptance:** A test PR triggers the workflow; the build + tests pass.

---

## Task 14: Version bump + CHANGELOG + tag

- [ ] Root `package.json` bump 2.1.0 → 2.2.0.
- [ ] `node scripts/sync-versions.js` + `node scripts/sync-package-meta.js`.
- [ ] CHANGELOG entry under `## [2.2.0] — YYYY-MM-DD` covering the RN module + everything in this plan.
- [ ] PUBLISHING.md (gitignored) — add npm publish step for `@dvai-bridge/react-native`.
- [ ] Commit + tag `v2.2.0` + push.

**Acceptance:**
- `pnpm install` succeeds at 2.2.0.
- `bash scripts/verify-cap-sync.sh` exits 0.
- `git tag --list | grep v2.2.0` shows the new tag.

---

## Test strategy summary

| Layer | Tool | Where |
|---|---|---|
| TS unit tests | Jest + ts-jest | `packages/dvai-bridge-react-native/src/__tests__/` |
| Type check | `tsc --noEmit` | per-package; CI workflow |
| iOS bridge sanity | `pod lib lint` against RN 0.77 sample | manual / CI |
| Android bridge sanity | RN sample's `:app:assembleDebug` | manual / CI |
| End-to-end runtime | RN 0.77 demo app (consumer-side, scripted) | docs only |

## Risk register

1. **TurboModule codegen output changes between RN minor versions.** Pin RN peerDep to `>= 0.77 < 1.0.0`. Test against the latest 0.77.x patch.
2. **MLX backend under CocoaPods**: known limitation from Phase 3C. Document; don't attempt to "fix" in 3E.
3. **Android sample app's GitHub Packages Maven repo setup is non-trivial** — consumers need a personal access token. Document the consumer-side `settings.gradle.kts` snippet thoroughly.
4. **Bridgeless mode incompatibility with RN ≤ 0.73**. Document; do not attempt to support legacy bridge in 3E.

## Out-of-scope

- Expo plugin (3H or later).
- React Server Components (RN doesn't ship them yet).
- Streaming responses (works through the existing HTTP `/v1/chat/completions` path).
- Sample app source — scripted only (per project convention).
- Flutter (3F), .NET (3G).

## References

- Spec: [docs/superpowers/specs/2026-04-27-phase3e-react-native-module-design.md](../specs/2026-04-27-phase3e-react-native-module-design.md)
- iOS counterpart spec: [docs/superpowers/specs/2026-04-26-phase3c-ios-native-sdk-design.md](../specs/2026-04-26-phase3c-ios-native-sdk-design.md)
- Android counterpart spec: [docs/superpowers/specs/2026-04-27-phase3d-android-native-sdk-design.md](../specs/2026-04-27-phase3d-android-native-sdk-design.md)
- React Native New Architecture: https://reactnative.dev/docs/the-new-architecture/landing-page
- TurboModules guide: https://reactnative.dev/docs/the-new-architecture/pure-cxx-modules
