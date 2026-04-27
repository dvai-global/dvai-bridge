# Phase 3F — Flutter Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to execute this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up `packages/dvai-bridge-flutter/` — pub.dev package `dvai_bridge`. A unified Flutter plugin (Pigeon-driven channel layer) that wraps the v2.2 iOS DVAIBridge SDK + v2.3 Android DVAIBridge SDK behind a shared Dart API.

**Architecture:** Dart facade (`DVAIBridge` class + `stateStream` / `progressStream` getters) → Pigeon-generated `DVAIBridgeHostApi` + `DVAIBridgeEventApi` → Swift plugin (calls `DVAIBridge.shared`) on iOS / Kotlin plugin (calls `co.deepvoiceai.bridge.DVAIBridge`) on Android. Reactive state surfaced via Pigeon `EventChannel` over `Combine` / `Flow` events.

**Tech stack (latest stable as of 2026-04-27):**
- Dart 3.9 (bundled with Flutter 3.41.5)
- Flutter 3.41.5 (consumer floor: 3.39.0)
- Pigeon 26.3.4 (dev dependency only)
- Swift 5.9+ (matches Phase 3C)
- Kotlin 2.1.x (matches Phase 3D)
- iOS deployment target: 15.1 (matches Phase 3C)
- Android minSdk: 24 (matches Phase 3D), compileSdk: 36
- AGP 8.7.x for the plugin module (Flutter plugin templates don't yet support AGP 9 — consumer app can use AGP 9.2 via Phase 3D umbrella)

**Spec:** [`docs/superpowers/specs/2026-04-27-phase3f-flutter-package-design.md`](../specs/2026-04-27-phase3f-flutter-package-design.md)

**Resolution of spec open questions (decided here, applied throughout):**

1. **Plugin pattern**: unified, single package. No federated split.
2. **Channel layer**: Pigeon 26.3.4. `@HostApi()` for the 4 lifecycle methods + `@EventChannelApi()` for progress.
3. **Distribution**: pub.dev as public package. Family asymmetry documented in `docs/migration/v2.2-to-v2.3.md`.
4. **Reactive state**: `Stream<DVAIBridgeState>` (the `stateStream` getter on the singleton). Consumers wrap in `ChangeNotifier` themselves if needed.
5. **Min Flutter / Dart**: Flutter 3.39.0 / Dart 3.7.0 in the consumer-facing constraint; CI tests against 3.41.5 (latest stable) and 3.39.x.
6. **Pigeon Swift output**: completion-handler protocol (Pigeon doesn't generate `actor`s as of 26.3.4); plugin impl wraps `await DVAIBridge.shared.start(...)` in a `Task { ... }`.
7. **Codegen output**: gitignored. Run `dart run pigeon` before `flutter analyze` / `flutter test` (CI step).

**Phase boundaries:**

- **Tasks 1-3**: Package scaffold + Pigeon spec + codegen wired up.
- **Tasks 4-5**: Public Dart types + Dart facade.
- **Tasks 6-7**: iOS Swift plugin + podspec.
- **Tasks 8-9**: Android Kotlin plugin + Gradle module.
- **Task 10**: Reactive `stateStream` derivation from progress events.
- **Task 11**: Dart unit tests.
- **Tasks 12-13**: Docs + CI workflow.
- **Task 14**: Version bump (2.2.0 → 2.3.0) + CHANGELOG + tag + pub.dev dry-run.

**Apply Phase 3C / 3D / 3E lessons up-front:**

1. **Pigeon parallels TurboModule codegen.** Both 3E and 3F have a "small spec → generated bindings on each side" pattern. The implementer's mental model from 3E carries over: write the spec narrowly, treat the generated code as opaque, do the strong-typing in the facade.
2. **iOS depends on the existing `DVAIBridge.podspec`** — no new podspec at the Flutter-bridge layer wraps the SDK. Just declare a podspec with `s.dependency 'DVAIBridge', '~> 2.2'`.
3. **Android dep via `co.deepvoiceai:dvai-bridge:2.3.0`** through GitHub Packages Maven. The consumer's app's Gradle config needs the maven repo entry — document in the consumer guide. Bump the Phase 3D AAR to 2.3.0 in the same release for build-graph consistency (no Android source changes — just a republish of the AAR with the new Gradle property `dvaiBridgeVersion=2.3.0`).
4. **Bridgeless / old-arch dual mode is not a thing for Flutter.** Flutter has only one plugin pattern (channel-based); no analogue to RN's TurboModule-vs-bridge bifurcation. Skip the corresponding analysis from 3E.
5. **Always pin to LATEST stable** for Flutter, Dart, Pigeon, Kotlin, AGP per the user's standing instruction. Re-verify on flutter.dev / pub.dev at task start in case a newer patch shipped after 2026-04-27.
6. **Mirror iOS DVAIBridge / Android DVAIBridge naming where practical**, but Dart uses lowerCamelCase enum values (`BackendKind.auto`, `BackendKind.llama`) and snake_case package name (`dvai_bridge`) per Dart convention. The native plugin classes use `DVAIBridgeFlutterPlugin` to disambiguate from the SDK's own `DVAIBridge`.
7. **Cross-platform-only validation in Dart facade.** Native plugins are still authoritative — they throw `backendUnavailable` if a consumer talks to the Pigeon channel directly.

---

## Task 1: Scaffold `dvai-bridge-flutter` package

**Files:**
- Create: `packages/dvai-bridge-flutter/package.json`
- Create: `packages/dvai-bridge-flutter/pubspec.yaml`
- Create: `packages/dvai-bridge-flutter/.gitignore`
- Create: `packages/dvai-bridge-flutter/analysis_options.yaml`
- Create: `packages/dvai-bridge-flutter/README.md` (placeholder; synced via `scripts/sync-package-meta.js`)
- Create: `packages/dvai-bridge-flutter/CHANGELOG.md` (placeholder)
- Create: `packages/dvai-bridge-flutter/lib/.gitkeep`
- Create: `packages/dvai-bridge-flutter/ios/.gitkeep`
- Create: `packages/dvai-bridge-flutter/android/.gitkeep`
- Create: `packages/dvai-bridge-flutter/pigeons/.gitkeep`
- Create: `packages/dvai-bridge-flutter/test/.gitkeep`
- Update: `pnpm-workspace.yaml` (add `packages/dvai-bridge-flutter`)
- Update: `scripts/sync-versions.js` (register the new package's pubspec.yaml as a version-tracked file)
- Update: `scripts/sync-package-meta.js` (sync README + version metadata)

- [ ] Verify latest stable on pub.dev / flutter.dev: `flutter`, `dart`, `pigeon`, `flutter_lints`, `mockito`, `build_runner`. Use those in `pubspec.yaml`.
- [ ] `package.json`: minimal — `"name": "@dvai-bridge/flutter"`, `"version": "2.2.0"` (will be bumped by Task 14), `"private": true`, `"scripts": { "pigeon": "dart run pigeon --input pigeons/messages.dart", "analyze": "flutter analyze", "test": "flutter test", "build": "flutter pub get && dart run pigeon --input pigeons/messages.dart" }`. Marked `private: true` because the actual publish is to pub.dev, not npm.
- [ ] `pubspec.yaml`:
  ```yaml
  name: dvai_bridge
  description: Local-LLM bridge with OpenAI-compatible HTTP server for Flutter (iOS/Android).
  version: 2.2.0
  homepage: https://github.com/deep-voice-ai/dvai-bridge
  repository: https://github.com/deep-voice-ai/dvai-bridge
  environment:
    sdk: ">=3.7.0 <4.0.0"
    flutter: ">=3.39.0"
  dependencies:
    flutter:
      sdk: flutter
  dev_dependencies:
    flutter_test:
      sdk: flutter
    flutter_lints: ^5.0.0   # verify latest at task start
    pigeon: ^26.3.4         # verify latest at task start
    mockito: ^5.4.4         # verify latest at task start
    build_runner: ^2.4.13   # verify latest at task start
  flutter:
    plugin:
      platforms:
        android:
          package: co.deepvoiceai.bridge.flutter
          pluginClass: DVAIBridgeFlutterPlugin
        ios:
          pluginClass: DVAIBridgeFlutterPlugin
  ```
- [ ] `analysis_options.yaml`: `include: package:flutter_lints/flutter.yaml`, plus `analyzer.errors.unawaited_futures: error` and `linter.rules.public_member_api_docs: true`.
- [ ] `.gitignore`: `.dart_tool/`, `build/`, `.flutter-plugins`, `.flutter-plugins-dependencies`, `.packages`, `pubspec.lock` (per Flutter library convention), `lib/src/messages.g.dart`, `ios/Classes/Messages.g.swift`, `android/src/main/kotlin/co/deepvoiceai/bridge/flutter/Messages.g.kt`.

**Acceptance:** `pnpm install` (workspace level) recognizes the new package directory; `flutter pub get` inside `packages/dvai-bridge-flutter/` resolves clean; `flutter analyze` exits 0 against the empty `lib/`.

---

## Task 2: Pigeon spec — `pigeons/messages.dart`

**Files:**
- Create: `packages/dvai-bridge-flutter/pigeons/messages.dart`

- [ ] Write the Pigeon spec per spec §3.3. Includes: `StartOptionsMessage`, `BoundServerMessage`, `StatusInfoMessage`, `DownloadOptionsMessage`, `DownloadResultMessage`, `ProgressEventMessage`, `@HostApi() abstract class DVAIBridgeHostApi`, `@EventChannelApi() abstract class DVAIBridgeEventApi`.
- [ ] `@ConfigurePigeon` block emits to `lib/src/messages.g.dart`, `ios/Classes/Messages.g.swift`, `android/src/main/kotlin/co/deepvoiceai/bridge/flutter/Messages.g.kt` with package `co.deepvoiceai.bridge.flutter`.
- [ ] All 4 host-api methods marked `@async` (Dart `Future<T>` ↔ Swift completion handler ↔ Kotlin completion handler).
- [ ] `progressEvents()` on the event API returns `ProgressEventMessage` (single-event stream, Pigeon translates to `EventChannel.StreamHandler`).

**Acceptance:** `dart run pigeon --input pigeons/messages.dart` from `packages/dvai-bridge-flutter/` exits 0 and writes the three generated files. Generated files are gitignored (Task 1) but should compile when present (`flutter analyze` over the package after codegen ⇒ 0 issues).

---

## Task 3: Public Dart types — `types.dart`, `errors.dart`, `progress.dart`

**Files:**
- Create: `packages/dvai-bridge-flutter/lib/src/types.dart`
- Create: `packages/dvai-bridge-flutter/lib/src/errors.dart`
- Create: `packages/dvai-bridge-flutter/lib/src/progress.dart`

- [ ] `types.dart`: `BackendKind` enum (7 values: `auto`, `llama`, `foundation`, `coreml`, `mlx`, `mediapipe`, `litert`); `StartOptions` immutable class (modelPath, tokenizerPath, mmprojPath, contextSize, threads, gpuLayers, httpBasePort, httpMaxPortAttempts, corsOrigin, temperature, topP, topK, maxNewTokens, modelId, backend, embeddingMode, visionEnabled — `backend` required, rest optional matching the iOS/Android shape); `BoundServer` (baseUrl, port, backend, modelId); `StatusInfo` (running, baseUrl?, port?, backend?, modelId?); `DownloadOptions` (url, sha256, destFilename?); `DownloadResult` (path, sha256, sizeBytes). Each class has a `toMessage()` (forward) and `static fromMessage(...)` (reverse) for Pigeon interop. `BackendKind` helpers: `BackendKind.fromName(String)`, `BackendKind.name` already exists in Dart.
- [ ] `errors.dart`: `sealed class DVAIBridgeError implements Exception` with constructors `alreadyStarted({required BackendKind backend, required String baseUrl})`, `configurationInvalid(String reason)`, `modelLoadFailed(String reason)`, `backendUnavailable({required BackendKind backend, required String reason})`, `backendError(String underlying)`, `checksumMismatch({required String expected, required String got})`, `downloadFailed(String reason)`. `kind` property returns the discriminator string mirrored across iOS / Android. Sealed class lets consumers `switch` on the exception with exhaustiveness.
- [ ] `progress.dart`: `enum ProgressKind { started, progress, completed, failed }`, `enum ProgressPhase { start, stop, download, load, ready, verify, error }`, immutable `ProgressEvent` (kind, phase, percent?, message?, errorKind?, errorMessage?), immutable `DVAIBridgeState` (isReady, baseUrl?, port?, backend?, modelId?, lastError?). `fromMessage` constructors for both.

**Acceptance:** `flutter analyze` reports 0 issues against the three new files. `dart doc` produces documentation for all public types (no missing-doc warnings under `public_member_api_docs`).

---

## Task 4: Dart facade — `dvai_bridge.dart` (private + public)

**Files:**
- Create: `packages/dvai-bridge-flutter/lib/src/dvai_bridge.dart`
- Create: `packages/dvai-bridge-flutter/lib/dvai_bridge.dart`

- [ ] `lib/src/dvai_bridge.dart`: `class DVAIBridge` with `static final instance = DVAIBridge._();`. Internal fields: `late final DVAIBridgeHostApi _api` (Pigeon-generated), `late final Stream<ProgressEvent> _progressStream` (lazy from EventChannel API), `final StreamController<DVAIBridgeState> _stateController = StreamController.broadcast()`, latest-state cache. Public methods:
  - `Future<BoundServer> start(StartOptions opts)` — runs the BackendKind platform-validation check (spec §3.4) before delegating to `_api.start`. Wraps Pigeon `PlatformException` in `DVAIBridgeError` based on the `code` field.
  - `Future<void> stop()` — delegates to `_api.stop`.
  - `Future<StatusInfo> status()` — delegates to `_api.status`.
  - `Future<DownloadResult> downloadModel(DownloadOptions opts)` — delegates to `_api.downloadModel`.
  - `Stream<ProgressEvent> get progressStream` — exposes the Pigeon EventChannel as the typed stream (one stream per call).
  - `Stream<DVAIBridgeState> get stateStream` — broadcast stream fed by an internal subscription to `progressStream` that maps `(kind=completed, phase=start)` ⇒ a fresh `status()` call ⇒ a `DVAIBridgeState(isReady: true, ...)`, and `(kind=completed, phase=stop)` ⇒ idle state.
  - `@visibleForTesting DVAIBridge.test(DVAIBridgeHostApi api, DVAIBridgeEventApi eventApi)` — test seam.
- [ ] `lib/dvai_bridge.dart`: re-exports `DVAIBridge`, `BackendKind`, `StartOptions`, `BoundServer`, `StatusInfo`, `DownloadOptions`, `DownloadResult`, `ProgressEvent`, `ProgressKind`, `ProgressPhase`, `DVAIBridgeState`, `DVAIBridgeError`. Does **not** re-export the Pigeon-generated types — those stay in `src/messages.g.dart`.
- [ ] `PlatformException` mapping: catch the Pigeon error, extract `code`, look up the matching `DVAIBridgeError` constructor, rethrow.

**Acceptance:** `flutter analyze` exits 0. The facade compiles against the generated `messages.g.dart` from Task 2.

---

## Task 5: iOS podspec

**Files:**
- Create: `packages/dvai-bridge-flutter/ios/dvai_bridge.podspec`

- [ ] Podspec declares: `s.name = 'dvai_bridge'`, `s.version = '2.2.0'` (will bump in Task 14), `s.platform = :ios, '15.1'`, `s.swift_version = '5.9'`, `s.source_files = 'Classes/**/*.{swift,h,m}'`, `s.dependency 'Flutter'`, `s.dependency 'DVAIBridge', '~> 2.2'` (the Phase 3C umbrella podspec; `~> 2.2` allows 2.2.x and 2.3.x patches without breaking-change risk).
- [ ] Document the MLX-under-CocoaPods caveat as a comment in the podspec (mirrors the Phase 3E iOS podspec).
- [ ] `s.pod_target_xcconfig` with `DEFINES_MODULE = YES` (Flutter plugin convention).

**Acceptance:** `pod lib lint dvai_bridge.podspec --allow-warnings` passes against a Flutter 3.41.5 sample's `Podfile`.

---

## Task 6: iOS Swift plugin — `DVAIBridgeFlutterPlugin.swift`

**Files:**
- Create: `packages/dvai-bridge-flutter/ios/Classes/DVAIBridgeFlutterPlugin.swift`

- [ ] `DVAIBridgeFlutterPlugin: NSObject, FlutterPlugin, DVAIBridgeHostApi`. Implements:
  - `static func register(with registrar: FlutterPluginRegistrar)` — calls `DVAIBridgeHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: self)` and `DVAIBridgeEventApiSetup.setUp(binaryMessenger: registrar.messenger(), streamHandler: self)`.
  - `start(opts: StartOptionsMessage, completion: @escaping (Result<BoundServerMessage, Error>) -> Void)` — opens `Task { do { let server = try await DVAIBridge.shared.start(opts.toConfig()); completion(.success(server.toMessage())) } catch let e as DVAIBridgeError { completion(.failure(PigeonError(code: e.kind, message: e.localizedMessage, details: nil))) } catch { completion(.failure(error)) } }`.
  - Same shape for `stop`, `status`, `downloadModel`.
- [ ] EventChannel impl: subscribes to `DVAIBridge.shared.progressPublisher` on first listener, sends `ProgressEventMessage` via the Pigeon-generated `pigeonEventSink`. Cancels on `onCancel`. Use a single `AnyCancellable` stored on the plugin instance; clear it on `onCancel`.
- [ ] Translation helpers: `StartOptionsMessage.toConfig() -> DVAIBridgeConfig`, `BoundServer.toMessage()`, `StatusInfo.toMessage()`, `DownloadResult.toMessage()`. Backend string ↔ `BackendKind` round-trip.
- [ ] Error mapping: `DVAIBridgeError.kind` → string code; `localizedMessage` → message field. Codes: `"alreadyStarted"`, `"configurationInvalid"`, `"modelLoadFailed"`, `"backendUnavailable"`, `"backendError"`, `"checksumMismatch"`, `"downloadFailed"`.

**Acceptance:** With a sample Flutter 3.41.5 app, building for iOS Simulator succeeds; calling `DVAIBridge.instance.start(...)` from Dart lands at the Swift method without crash.

---

## Task 7: Android Gradle module + Kotlin plugin

**Files:**
- Create: `packages/dvai-bridge-flutter/android/build.gradle`
- Create: `packages/dvai-bridge-flutter/android/settings.gradle`
- Create: `packages/dvai-bridge-flutter/android/gradle.properties`
- Create: `packages/dvai-bridge-flutter/android/src/main/AndroidManifest.xml`
- Create: `packages/dvai-bridge-flutter/android/src/main/kotlin/co/deepvoiceai/bridge/flutter/DVAIBridgeFlutterPlugin.kt`

- [ ] `build.gradle`: AGP 8.7.x, minSdk 24, compileSdk 36, JVM 17, Kotlin 2.1.x. Depends on `co.deepvoiceai:dvai-bridge:$dvaiBridgeVersion` (Gradle property) via `mavenCentral() + maven { url = uri("https://maven.pkg.github.com/deep-voice-ai/dvai-bridge"); credentials { ... } }`. Uses standard Flutter plugin Gradle setup (`apply plugin: 'com.android.library'`, `apply plugin: 'org.jetbrains.kotlin.android'`).
- [ ] `gradle.properties`: `dvaiBridgeVersion=2.3.0` (matches Phase 3D bump for this release).
- [ ] `AndroidManifest.xml`: minimal — empty `<manifest>` with the package attribute removed (AGP 8 stores it in `build.gradle` under `namespace`).
- [ ] `DVAIBridgeFlutterPlugin.kt`: `class DVAIBridgeFlutterPlugin : FlutterPlugin, DVAIBridgeHostApi`. Implements:
  - `onAttachedToEngine(binding)` — `DVAIBridgeHostApi.setUp(binding.binaryMessenger, this)`. Also `DVAIBridgeEventApi.setUp(binding.binaryMessenger, eventApiImpl)`. Calls `DVAIBridge.init(binding.applicationContext)`.
  - `onDetachedFromEngine(binding)` — clears the same setUps with `null`. Cancels `pluginScope`.
  - 4 host-api methods, each translating `*Message` → SDK type, calling `pluginScope.launch { try { val r = DVAIBridge.start(opts.toStartOptions()); callback(Result.success(r.toMessage())) } catch (e: DVAIBridgeError) { callback(Result.failure(...)) } }`.
- [ ] Plugin uses `private val pluginScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)`. Per-method work hops to `Dispatchers.IO` since the SDK methods are already `suspend`.
- [ ] EventChannel impl: collects `DVAIBridge.progressFlow` on plugin-scope, emits `ProgressEventMessage` via the Pigeon-generated event sink. Cancels collection on `onDetachedFromEngine`.
- [ ] Error mapping: `DVAIBridgeError.AlreadyStarted` → code `"alreadyStarted"`, etc. (mirrors iOS code strings exactly so the Dart facade's `PlatformException` switch is platform-agnostic).

**Acceptance:** Sample Flutter 3.41.5 app's `flutter build apk --debug` succeeds; calling `DVAIBridge.instance.start(...)` from Dart lands at the Kotlin method.

---

## Task 8: Phase 3D Android AAR republish at 2.3.0

**Files:**
- Update: `packages/dvai-bridge-android/android/gradle.properties` — `dvaiBridgeVersion=2.3.0` (bump from 2.2.0)
- Update: `packages/dvai-bridge-android/android/build.gradle` — bump publish version
- Update: `packages/dvai-bridge-android/CHANGELOG.md` — note "republish at 2.3.0 alongside Phase 3F Flutter plugin; no source changes"

- [ ] No Kotlin source changes; this is a build-graph alignment.
- [ ] CI re-runs the existing Android publish workflow at `v2.3.0` to push the new AAR artifact to GitHub Packages Maven.
- [ ] The Flutter plugin's `gradle.properties` (Task 7) references `2.3.0` so the build graph is internally consistent.

**Acceptance:** GitHub Packages shows `co.deepvoiceai:dvai-bridge:2.3.0` after the v2.3.0 tag is pushed (Task 14). The Flutter plugin's Gradle build resolves the new artifact.

---

## Task 9: Pigeon EventChannel wiring sanity

This is partially in Tasks 6 + 7; this task cross-checks that both emit consistent payloads and that the Dart subscriber sees both streams identically.

- [ ] Both iOS and Android emit `ProgressEventMessage { kind, phase, percent?, message?, errorKind?, errorMessage? }` with the same string-enum values: `kind ∈ {"started","progress","completed","failed"}`, `phase ∈ {"start","stop","download","load","ready","verify","error"}`. Document the union in `lib/src/progress.dart` doc comments.
- [ ] iOS: tap `DVAIBridge.shared.progressPublisher` (Combine), map to `ProgressEventMessage`, send via Pigeon event sink.
- [ ] Android: collect `DVAIBridge.progressFlow` on plugin scope, map to `ProgressEventMessage`, send via Pigeon event sink. Lifecycle: cancel collection on `onDetachedFromEngine`.
- [ ] Verify: a manual run of a Flutter sample app on each platform shows the progress events arriving with identical shapes (one start, N progress%, one completed).

**Acceptance:** A unit-style test (Task 11) subscribes to the Dart-side stream and asserts both shape and ordering against a fake event API.

---

## Task 10: Reactive `stateStream` derivation

Already partly described in Task 4; this task is the dedicated implementation + acceptance step.

**Files:**
- Update: `packages/dvai-bridge-flutter/lib/src/dvai_bridge.dart`

- [ ] Internal `_progressSubscription` set up at instance construction. Listens to `progressStream`; on `(kind: completed, phase: start)` calls `await status()` and emits a `DVAIBridgeState(isReady: true, baseUrl: ..., port: ..., backend: ..., modelId: ...)` on `_stateController`. On `(kind: completed, phase: stop)` emits `DVAIBridgeState(isReady: false)`. On `(kind: failed, phase: start)` emits `DVAIBridgeState(isReady: false, lastError: ...)`.
- [ ] First-listener bootstrap: when a consumer first listens to `stateStream`, call `status()` once and emit the current state immediately so `StreamBuilder` doesn't show a "waiting" widget if the bridge is already running.
- [ ] Cleanup: `dispose()` method on the singleton (rarely called, but useful in tests) cancels the subscription and closes the controller.

**Acceptance:** A small Flutter test (Task 11) wires a fake `DVAIBridgeEventApi` that emits a fake start-completed event; the test asserts that `stateStream.first` resolves with `isReady: true` and the right baseUrl.

---

## Task 11: Dart unit tests

**Files:**
- Create: `packages/dvai-bridge-flutter/test/dvai_bridge_test.dart`
- Create: `packages/dvai-bridge-flutter/test/types_test.dart`
- Create: `packages/dvai-bridge-flutter/test/state_stream_test.dart`

- [ ] Use mockito to mock `DVAIBridgeHostApi` + `DVAIBridgeEventApi`. Inject via `DVAIBridge.test(api, eventApi)` (Task 4 test seam).
- [ ] `dvai_bridge_test.dart`:
  - `start()` rejects iOS-only backend on Android (`DVAIBridgeError.backendUnavailable`).
  - `start()` rejects Android-only backend on iOS.
  - `start()` forwards opts and resolves the BoundServer shape.
  - `stop()` calls native and resolves void.
  - `start()` translates a Pigeon `PlatformException(code: 'alreadyStarted')` to `DVAIBridgeError.alreadyStarted`.
  - `downloadModel()` happy path returns the right `DownloadResult`.
- [ ] `types_test.dart`: round-trip every public type through `toMessage` / `fromMessage`. Assert all backend names round-trip.
- [ ] `state_stream_test.dart`: feed the fake event API a sequence of progress events (start → 3x progress → completed), assert `stateStream` emits the correct `DVAIBridgeState` transitions with the right cardinality.

**Acceptance:** `flutter test` runs all tests green inside the package. Coverage of the public facade ≥ 80%.

---

## Task 12: Docs — `flutter-sdk.md` + migration entry + sidebar

**Files:**
- Create: `docs/guide/flutter-sdk.md`
- Update: `docs/migration/v1.6-to-v2.0.md` (append a Flutter consumer pointer — short note; the actual migration is in v2.2 → v2.3)
- Create: `docs/migration/v2.2-to-v2.3.md`
- Update: `docs/.vitepress/config.ts` (sidebar add Flutter SDK page; add v2.2→v2.3 migration entry)

- [ ] `flutter-sdk.md` mirrors the structure of `ios-native-sdk.md` / `android-native-sdk.md` / `react-native-sdk.md`:
  - Install (`flutter pub add dvai_bridge`)
  - iOS prerequisites (Podfile platform: ios, '15.1'; CocoaPods source for the `DVAIBridge` pod)
  - Android prerequisites (settings.gradle.kts repo block with GitHub Packages Maven + GH PAT)
  - Quickstart (the §3.2 snippet from the spec, expanded into a runnable Flutter widget)
  - BackendKind table + platform availability
  - Reactive state via `StreamBuilder<DVAIBridgeState>` example
  - Riverpod `StreamProvider` example (idiomatic Flutter)
  - Bloc consumer example (idiomatic Flutter)
  - Error reference table — `DVAIBridgeError.kind` ↔ what it means ↔ recovery hint
  - MLX-under-CocoaPods caveat (same as iOS / RN docs)
  - Pub.dev distribution note (asymmetry vs the rest of the family)
- [ ] `v2.2-to-v2.3.md`: short migration note. Most users add a new dep (`flutter pub add dvai_bridge`); existing iOS/Android/RN users see no change. Note the AAR republish at 2.3.0 (Task 8) and the Flutter pub.dev distribution.
- [ ] Sidebar: add Flutter SDK under "Native SDKs" group below RN.

**Acceptance:** `pnpm run docs:dev` renders the new page; no broken links; `pnpm run docs:build` exits 0.

---

## Task 13: CI workflow

**Files:**
- Create: `.github/workflows/test-flutter.yml`

- [ ] Steps:
  1. checkout
  2. setup Flutter (matrix: 3.41.5 latest, 3.39.x oldest-supported)
  3. setup Java 17 (for the Android build)
  4. `flutter pub get` inside `packages/dvai-bridge-flutter/`
  5. `dart run pigeon --input pigeons/messages.dart` (codegen)
  6. `flutter analyze`
  7. `flutter test`
  8. (smoke iOS) — on `macos-latest` runner, `cd example_app && flutter build ios --simulator --no-codesign` against a scripted minimal example app (set up in this workflow inline; example/ in the package stays a README pointer per project convention)
  9. (smoke Android) — on `ubuntu-latest`, `cd example_app && flutter build apk --debug`
- [ ] Optional: `dart pub publish --dry-run` step on tag-push only, to catch publish-blocking warnings before the human runs the actual publish in `PUBLISHING.md`.

**Acceptance:** A test PR triggers the workflow; the analyze + test + both smoke builds pass on both Flutter versions in the matrix. The dry-run step succeeds on tag.

---

## Task 14: Version bump + CHANGELOG + tag + pub.dev publish prep

**Files:**
- Update: `package.json` (root) — bump 2.2.0 → 2.3.0
- Update: `packages/dvai-bridge-flutter/pubspec.yaml` — version 2.2.0 → 2.3.0
- Update: `packages/dvai-bridge-flutter/ios/dvai_bridge.podspec` — `s.version = '2.3.0'`
- Update: `packages/dvai-bridge-flutter/android/gradle.properties` — already 2.3.0 from Task 7
- Update: `packages/dvai-bridge-android/android/gradle.properties` — already 2.3.0 from Task 8
- Update: `packages/dvai-bridge-flutter/CHANGELOG.md` — release entry
- Update: `CHANGELOG.md` (root) — `## [2.3.0] — YYYY-MM-DD` covering the Flutter plugin + Android AAR republish
- Update: `PUBLISHING.md` (gitignored) — add `dart pub publish` step for `dvai_bridge` (the only public-pub publish in the family)

- [ ] `node scripts/sync-versions.js` + `node scripts/sync-package-meta.js`. Verify `pubspec.yaml`'s `version:` field is now in the version-tracker's known files.
- [ ] CHANGELOG entry under `## [2.3.0] — YYYY-MM-DD`:
  - Added: Flutter plugin `dvai_bridge` (pub.dev) — Pigeon-driven, iOS + Android.
  - Changed: Phase 3D Android AAR republished at 2.3.0 for build-graph alignment (no source changes).
  - Notes: Flutter plugin published to pub.dev (vs the rest of the family on GitHub Packages); see `docs/migration/v2.2-to-v2.3.md`.
- [ ] PUBLISHING.md flow:
  1. `git tag v2.3.0` + push
  2. CI publishes the Android AAR to GitHub Packages
  3. (manual) Run `cd packages/dvai-bridge-flutter && dart pub publish` (interactive; requires pub.dev login)
  4. Verify pub.dev page at https://pub.dev/packages/dvai_bridge shows 2.3.0 within 5 minutes
- [ ] Commit + tag `v2.3.0` + push.

**Acceptance:**
- `pnpm install` succeeds at 2.3.0.
- `bash scripts/verify-cap-sync.sh` exits 0 (existing script must tolerate the new pubspec.yaml; confirm or extend).
- `git tag --list | grep v2.3.0` shows the new tag.
- `dart pub publish --dry-run` from `packages/dvai-bridge-flutter/` exits 0.

---

## Test strategy summary

| Layer                      | Tool                                       | Where                                         |
|----------------------------|--------------------------------------------|-----------------------------------------------|
| Dart unit tests            | `flutter test` + `mockito` mocks           | `packages/dvai-bridge-flutter/test/`          |
| Pigeon codegen sanity      | `dart run pigeon` exit code                | CI workflow (Task 13)                         |
| Static analysis            | `flutter analyze` (strict-mode)            | per-package; CI workflow                      |
| iOS plugin sanity          | `pod lib lint` against Flutter 3.41 sample | manual / CI (Task 13)                         |
| iOS smoke                  | `flutter build ios --simulator`            | CI macos runner (Task 13)                     |
| Android smoke              | `flutter build apk --debug`                | CI ubuntu runner (Task 13)                    |
| End-to-end runtime         | Flutter 3.41 demo app (consumer-side)      | docs only — scripted per project convention   |
| Pub.dev publish dry-run    | `dart pub publish --dry-run`               | CI tag-push (Task 13) + manual pre-publish    |

## Risk register

1. **Pigeon API changes between minor versions.** Pin `pigeon: ^26.3.4` in `dev_dependencies`. Test the exact pinned version in CI. The generated code lives in `lib/src/messages.g.dart` etc. and is gitignored, so a Pigeon upgrade triggers a regen + diff review at upgrade time.
2. **MLX backend under CocoaPods**: known limitation from Phase 3C. Flutter consumers go through CocoaPods unconditionally (Flutter doesn't auto-route to SwiftPM). Document; don't attempt to "fix" in 3F.
3. **Android consumer's GitHub Packages Maven repo setup is non-trivial** — consumers need a personal access token. Document the consumer-side `settings.gradle.kts` snippet thoroughly (mirror the language used in `docs/guide/android-native-sdk.md`).
4. **Pub.dev publish requires a Google identity tied to a verified pub.dev publisher.** Add this prerequisite to PUBLISHING.md. The first publish must come from a maintainer's pub.dev account; subsequent publishes can use `pub.dev` API tokens via CI (set up in Phase 3H).
5. **Flutter plugin's AGP 8.7 lags consumer apps on AGP 9.2.** Should be transparent (Gradle resolves the plugin's compileClasspath separately), but flag it in the README so Android-savvy consumers don't get surprised by the asymmetry.
6. **`environment.flutter: '>=3.39.0'` may be tighter than necessary, but Pigeon 26 needs Dart 3.9 to *generate* — consumers don't run Pigeon, just consume the generated `.g.dart`.** If a consumer hits a runtime issue on Flutter 3.39 (Dart 3.7), drop the floor in a 2.3.1 patch. Sentry-track Flutter version distribution post-launch.
7. **`StreamController` leaks if `dispose()` is never called.** Acceptable for a singleton; the controller lives for the process lifetime. Document in the API docs that singleton state is process-scoped.

## Out-of-scope

- Flutter Web / Desktop platforms (Phase 3H+).
- Federated plugin split (only worth it if a third-party platform impl appears).
- `ChangeNotifier` API (consumers wrap the Stream in 4 lines if they want it).
- Streaming responses via custom transport (works through the existing HTTP `/v1/chat/completions` SSE path).
- Sample app source — scripted only (per project convention).
- iOS / Android source changes beyond the AAR republish at 2.3.0 (Task 8).
- .NET (3G), launch (3H).

## References

- Spec: [docs/superpowers/specs/2026-04-27-phase3f-flutter-package-design.md](../specs/2026-04-27-phase3f-flutter-package-design.md)
- iOS counterpart spec: [docs/superpowers/specs/2026-04-26-phase3c-ios-native-sdk-design.md](../specs/2026-04-26-phase3c-ios-native-sdk-design.md)
- Android counterpart spec: [docs/superpowers/specs/2026-04-27-phase3d-android-native-sdk-design.md](../specs/2026-04-27-phase3d-android-native-sdk-design.md)
- React Native counterpart plan: [docs/superpowers/plans/2026-04-27-phase3e-react-native-module.md](2026-04-27-phase3e-react-native-module.md)
- Flutter 3.41 release notes: https://docs.flutter.dev/release/release-notes/release-notes-3.41.0
- Flutter supported platforms: https://docs.flutter.dev/reference/supported-platforms
- Pigeon package: https://pub.dev/packages/pigeon
- Pigeon EventChannelApi (since 22.7): https://pub.dev/packages/pigeon/changelog
- pub.dev publishing: https://dart.dev/tools/pub/publishing
- Federated plugin guide (rejected for 3F): https://docs.flutter.dev/packages-and-plugins/developing-packages#federated-plugins
