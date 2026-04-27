# Phase 3F — Flutter Plugin (`dvai_bridge`)

**Status:** Draft — awaiting review
**Date:** 2026-04-27
**Scope:** A unified Flutter plugin that wraps the Phase 3C iOS Native SDK + Phase 3D Android Native SDK behind a single Dart API. Drop-in for any Flutter ≥ 3.39 (current stable minus two minor versions); zero Dart-side inference engine, zero `dart:ffi` calls. Communication with the host platform is via Pigeon-generated, type-safe platform channels.

**Sub-phase position in Phase 3:**

```
3A core extraction ✅ → 3B LiteRT-LM migration ✅ → 3C iOS SDK ✅
                                                  → 3D Android AAR ✅
                                                  → 3E React Native ✅
                                                  → 3F Flutter ◀️ YOU ARE HERE
                                                  → 3G .NET NuGet
                                                  → 3H docs / publish / launch
```

3F is structurally identical to 3E: both native SDKs already speak the same `DVAIBridge` shape (8-method singleton + reactive state). 3F is a Flutter plugin that translates Dart calls into native calls, and surfaces the OpenAI-compatible HTTP server's `baseUrl` so consumers point any OpenAI-compatible Dart HTTP client (e.g. `package:openai_client`, `package:http`) at `http://127.0.0.1:<port>/v1`.

---

## 1. Goals

1. Stand up `packages/dvai-bridge-flutter/` — pub.dev package `dvai_bridge` (snake_case per Dart convention). Single facade (`DVAIBridge` Dart class) that surfaces the 8-method DVAIBridge API to Dart / Flutter consumers.
2. Public Dart API mirrors the iOS / Android shape:
   ```dart
   import 'package:dvai_bridge/dvai_bridge.dart';

   final server = await DVAIBridge.instance.start(StartOptions(
     backend: BackendKind.auto,
     modelPath: '/path/to/model.gguf',
   ));
   print(server.baseUrl); // http://127.0.0.1:38883/v1
   await DVAIBridge.instance.stop();
   ```
3. Two thin bridging targets in the same package (unified plugin layout):
   - **iOS bridge**: Swift class (`DVAIBridgeFlutterPlugin`) implementing the Pigeon-generated `DVAIBridgeHostApi` protocol, depending on `DVAIBridge` (the SwiftPM/CocoaPods target from Phase 3C v2.1+) and translating Pigeon calls into `DVAIBridge.shared.start(...)` etc.
   - **Android bridge**: Kotlin class (`DVAIBridgeFlutterPlugin`) implementing the Pigeon-generated `DVAIBridgeHostApi` interface, depending on `co.deepvoiceai:dvai-bridge:2.2.0` (Phase 3D umbrella AAR — bumped to 2.2.0 alongside this plugin) and translating Pigeon calls into `DVAIBridge.start(...)`.
4. Cross-platform `BackendKind` is the **union** of iOS and Android cases:
   ```dart
   enum BackendKind {
     auto,
     llama,
     foundation,  // iOS-only
     coreml,      // iOS-only
     mlx,         // iOS-only
     mediapipe,   // Android-only
     litert,      // Android-only
   }
   ```
   Native modules throw `DVAIBridgeError.backendUnavailable` when the requested backend doesn't exist on the platform; the Dart facade pre-validates so consumers get a fast-fail before crossing the channel.
5. Reactive state surface: `Stream<DVAIBridgeState>` exposed as `DVAIBridge.instance.stateStream`, backed by a Pigeon `EventChannel` over the iOS `Combine` / Android `Flow` events. Idiomatic Flutter: drop into `StreamBuilder`, Riverpod `StreamProvider`, Bloc, or wrap in a `ChangeNotifier` if the consumer prefers Provider. **Polling-free.**
6. Build pipeline: Dart source → analyzer-clean strict mode. Pigeon spec (`pigeons/messages.dart`) generates `lib/src/messages.g.dart` (Dart side) + `ios/Classes/Messages.g.swift` (iOS side) + `android/src/main/kotlin/.../Messages.g.kt` (Android side) at dev time via `dart run pigeon`.

## 2. Non-goals (3F)

- **WebRTC / streaming over a custom transport** — Flutter consumers stream chat completions through the existing HTTP `/v1/chat/completions` SSE path using any OpenAI-compatible Dart HTTP client. 3F doesn't add a new transport.
- **Zero-rebuild model swap** — same as the underlying SDKs: `start()` / `stop()` cycles around model changes.
- **Web / desktop platforms** — `dart:js` / `dart:ffi` builds aren't in scope. Flutter Web / macOS / Linux / Windows are out of scope for 3F (the underlying iOS/Android SDKs are the only ones that exist). The plugin manifest declares only `ios` and `android`. **Flutter desktop is a Phase 3H+ follow-up.**
- **Federated plugin split** — 3F ships as a single unified package. Federated splits (`dvai_bridge_platform_interface` + `dvai_bridge_ios` + `dvai_bridge_android`) are only worth the ceremony if a third-party plans to ship an alternate platform impl, which isn't on the roadmap.
- **`ChangeNotifier` API** — modern Flutter idioms favour `Stream`. Consumers who want `ChangeNotifier` can wrap the stream themselves in 4 lines.
- **Sample app** — out of scope (per the project's "scripted samples" convention). Docs include a copy-paste-ready snippet and `example/README.md` is a pointer to the docs page.
- **Flutter ≤ 3.38** — Pigeon 26 requires Dart 3.9 (Flutter 3.41+); we set the floor at Flutter 3.39 for two minor versions of headroom but consumers below that should pin a Flutter 3.41+ toolchain.

## 3. Architecture

### 3.1 Package layout

```
packages/dvai-bridge-flutter/
├── package.json                                    # @dvai-bridge/flutter — npm-graph integration only
│                                                   # (no actual npm publish; lets pnpm-workspace see the dir)
├── pubspec.yaml                                    # the actual Flutter package manifest, name: dvai_bridge
├── README.md                                       # synced via scripts/sync-package-meta.js
├── CHANGELOG.md
├── analysis_options.yaml                           # extends package:flutter_lints/flutter.yaml
├── lib/
│   ├── dvai_bridge.dart                            # public facade — re-exports everything
│   ├── src/
│   │   ├── dvai_bridge.dart                        # DVAIBridge class (start/stop/status/etc.)
│   │   ├── types.dart                              # BackendKind, StartOptions, BoundServer, StatusInfo
│   │   ├── errors.dart                             # DVAIBridgeError sealed class hierarchy
│   │   ├── progress.dart                           # ProgressEvent + DVAIBridgeState
│   │   └── messages.g.dart                         # Pigeon-generated platform channel bindings (gitignored)
├── pigeons/
│   └── messages.dart                               # Pigeon spec source — committed
├── ios/
│   ├── dvai_bridge.podspec                         # depends on DVAIBridge umbrella from Phase 3C
│   └── Classes/
│       ├── DVAIBridgeFlutterPlugin.swift           # implements Pigeon DVAIBridgeHostApi protocol
│       └── Messages.g.swift                        # Pigeon-generated (gitignored)
├── android/
│   ├── build.gradle                                # depends on co.deepvoiceai:dvai-bridge:2.2.0
│   ├── settings.gradle
│   └── src/main/kotlin/co/deepvoiceai/bridge/flutter/
│       ├── DVAIBridgeFlutterPlugin.kt              # implements Pigeon DVAIBridgeHostApi interface
│       └── Messages.g.kt                           # Pigeon-generated (gitignored)
├── test/
│   └── dvai_bridge_test.dart                       # Dart unit tests (mockito + pigeon mocks)
└── example/                                        # scripted, not implemented (per project convention)
    └── README.md                                   # quickstart pointing at the consumer guide
```

### 3.2 Public API surface (Dart)

```dart
import 'package:dvai_bridge/dvai_bridge.dart';

final server = await DVAIBridge.instance.start(StartOptions(
  backend: BackendKind.auto,
  modelPath: '/path/to/model.gguf',
  contextSize: 2048,
  threads: 4,
));

print(server.baseUrl);  // http://127.0.0.1:38883/v1
print(server.port);     // 38883
print(server.backend);  // BackendKind.llama
print(server.modelId);

final status = await DVAIBridge.instance.status();
await DVAIBridge.instance.stop();

// Reactive state — Stream<DVAIBridgeState> backed by an EventChannel.
DVAIBridge.instance.stateStream.listen((state) {
  print('${state.isReady} ${state.baseUrl} ${state.backend}');
});

// Progress events — same EventChannel, different payload shape.
final sub = DVAIBridge.instance.progressStream.listen((event) {
  print(event);
});
await sub.cancel();
```

`DVAIBridge` is a regular Dart class with a static `instance` (singleton). The constructor stays public (`DVAIBridge.test()`) so unit tests can inject a fake `DVAIBridgeHostApi`, mirroring the iOS-side test-isolation pattern of constructing a fresh `DVAIBridge()` actor.

### 3.3 Pigeon spec sketch

```dart
// pigeons/messages.dart — committed, source of truth for the channel layer.
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(PigeonOptions(
  dartOut: 'lib/src/messages.g.dart',
  swiftOut: 'ios/Classes/Messages.g.swift',
  kotlinOut: 'android/src/main/kotlin/co/deepvoiceai/bridge/flutter/Messages.g.kt',
  kotlinOptions: KotlinOptions(package: 'co.deepvoiceai.bridge.flutter'),
  swiftOptions: SwiftOptions(),
  dartPackageName: 'dvai_bridge',
))
class StartOptionsMessage {
  String? modelPath;
  String? tokenizerPath;
  String? mmprojPath;
  int? contextSize;
  int? threads;
  int? gpuLayers;
  int? httpBasePort;
  int? httpMaxPortAttempts;
  String? corsOrigin;
  double? temperature;
  double? topP;
  int? topK;
  int? maxNewTokens;
  String? modelId;
  String? backend; // serialized BackendKind ("auto", "llama", "foundation", ...)
  bool? embeddingMode;
  bool? visionEnabled;
}

class BoundServerMessage {
  late String baseUrl;
  late int port;
  late String backend;
  late String modelId;
}

class StatusInfoMessage {
  late bool running;
  String? baseUrl;
  int? port;
  String? backend;
  String? modelId;
}

class DownloadOptionsMessage {
  late String url;
  late String sha256;
  String? destFilename;
}

class DownloadResultMessage {
  late String path;
  late String sha256;
  late int sizeBytes;
}

class ProgressEventMessage {
  late String kind;       // "started" | "progress" | "completed" | "failed"
  late String phase;      // "start" | "stop" | "download" | "load" | "ready" | "verify" | "error"
  double? percent;
  String? message;
  String? errorKind;
  String? errorMessage;
}

@HostApi()
abstract class DVAIBridgeHostApi {
  @async
  BoundServerMessage start(StartOptionsMessage opts);

  @async
  void stop();

  @async
  StatusInfoMessage status();

  @async
  DownloadResultMessage downloadModel(DownloadOptionsMessage opts);
}

@EventChannelApi()
abstract class DVAIBridgeEventApi {
  ProgressEventMessage progressEvents();
}
```

The `@HostApi()` translates to a Swift `protocol` and Kotlin `interface`; native plugins provide an implementation that calls the underlying SDK. The `@EventChannelApi()` (Pigeon 22.7+) generates a typed `EventChannel` that supersedes hand-written `EventChannel` glue.

`@async` methods become Dart `Future<T>` and Swift / Kotlin completion-handler signatures. Inside the Swift impl, the body opens a `Task { ... }` and bridges `await DVAIBridge.shared.start(...)` to the completion handler. Inside the Kotlin impl, the body launches a `CoroutineScope(Dispatchers.IO).launch { ... }` and bridges `DVAIBridge.start(...)` similarly.

### 3.4 Cross-platform validation

Because `BackendKind` is the union of iOS and Android cases, the Dart facade does first-pass validation:

```dart
import 'dart:io' show Platform;

const _iosOnly = {BackendKind.foundation, BackendKind.coreml, BackendKind.mlx};
const _androidOnly = {BackendKind.mediapipe, BackendKind.litert};

Future<BoundServer> start(StartOptions opts) async {
  if (Platform.isIOS && _androidOnly.contains(opts.backend)) {
    throw DVAIBridgeError.backendUnavailable(
      backend: opts.backend,
      reason: '${opts.backend.name} is Android-only',
    );
  }
  if (Platform.isAndroid && _iosOnly.contains(opts.backend)) {
    throw DVAIBridgeError.backendUnavailable(
      backend: opts.backend,
      reason: '${opts.backend.name} is iOS-only',
    );
  }
  final msg = await _api.start(opts.toMessage());
  return BoundServer.fromMessage(msg);
}
```

The native modules are still authoritative — they throw a matching `backendUnavailable` if the consumer somehow bypasses the Dart check (e.g. by talking to the Pigeon channel directly).

### 3.5 Reactive state via Pigeon `EventChannel`

Both native sides emit `ProgressEvent`s. The Swift plugin wraps `DVAIBridge.shared.progressPublisher` (Combine) as a Pigeon `EventChannel.StreamHandler`, the Kotlin plugin does the same with `DVAIBridge.progressFlow`. The Dart facade exposes two views over the same source:

```dart
class DVAIBridge {
  /// Raw progress event stream. One event per backend phase transition.
  Stream<ProgressEvent> get progressStream => _eventApi.progressEvents()
      .map(ProgressEvent.fromMessage);

  /// Derived "is the bridge running" view. Latest-value cache + start/stop edges.
  Stream<DVAIBridgeState> get stateStream => _stateController.stream;

  // _stateController is fed by a private subscription to progressStream that
  // calls status() on `completed phase=start` and emits a ready DVAIBridgeState,
  // and emits an idle state on `completed phase=stop` / `failed phase=start`.
}
```

Consumers who use Bloc or Riverpod consume `stateStream` directly via `StreamProvider`. Consumers on Provider can wrap it:

```dart
final notifier = ChangeNotifier();
DVAIBridge.instance.stateStream.listen((s) => notifier.notifyListeners());
```

### 3.6 Threading model

- **Dart side**: pure async/await; no isolates. Pigeon handles channel-marshalling on the platform thread automatically.
- **iOS side**: Swift plugin opens a `Task { ... }` per `@async` method; `DVAIBridge` is an `actor`, so calls into it are already serialized.
- **Android side**: Kotlin plugin uses a single `CoroutineScope(SupervisorJob() + Dispatchers.IO)` per plugin instance (cancelled on `onDetachedFromEngine`). `DVAIBridge` is a Kotlin `object` with an internal `Mutex`, so calls are already serialized.

## 4. Distribution

### 4.1 pub.dev — public package

The dvai-bridge family publishes JS to GitHub Packages npm and Maven artifacts to GitHub Packages Maven. **Flutter consumers expect packages to be installable from pub.dev**, and there is no first-class private-pub equivalent (`pub_hosted_url` overrides + self-hosted pub server are theoretically possible but operationally unattractive for one package). 3F therefore publishes `dvai_bridge` to **pub.dev as a public package**.

Asymmetry note (call out in `docs/migration/v2.2-to-v2.3.md`):

| Family member            | Distribution                                   | Public/Private |
|--------------------------|------------------------------------------------|----------------|
| `@dvai-bridge/capacitor` | npm (GitHub Packages)                          | private        |
| `@dvai-bridge/ios`       | SwiftPM (GitHub repo) + CocoaPods (Trunk)      | public (CocoaPods) / private (GH SPM auth optional) |
| `@dvai-bridge/android`   | Maven (GitHub Packages)                        | private        |
| `@dvai-bridge/react-native` | npm (GitHub Packages)                       | private        |
| `dvai_bridge` (Flutter)  | **pub.dev**                                    | **public**     |
| `@dvai-bridge/dotnet`    | NuGet (GitHub Packages — planned 3G)           | private        |

The CocoaPods publish is already public (Trunk has no private-feed support short of self-hosted pods). The Flutter plugin joins it as the second publicly-distributed family member. The package code itself is OSS-friendly; the underlying native AARs / Swift packages are still private and the consumer pulls them in via Maven Central proxy (Phase 3D) / SwiftPM authenticated checkout (Phase 3C). Document this clearly in the README so consumers don't expect the Flutter plugin alone to be useful — they still need the Maven / SwiftPM dep with a GitHub PAT.

### 4.2 Native autolinking

Flutter discovers plugins through `pubspec.yaml` declarations:

```yaml
flutter:
  plugin:
    platforms:
      android:
        package: co.deepvoiceai.bridge.flutter
        pluginClass: DVAIBridgeFlutterPlugin
      ios:
        pluginClass: DVAIBridgeFlutterPlugin
```

iOS pulls the podspec from `ios/dvai_bridge.podspec`; Android pulls the Gradle module from `android/build.gradle`. No `react-native.config.js`-equivalent is needed.

### 4.3 Consumer integration

```bash
flutter pub add dvai_bridge
```

Then, on iOS, the consumer's `Podfile` needs:

```ruby
platform :ios, '15.1'                              # matches iOS SDK floor
source 'https://cdn.cocoapods.org/'                # for DVAIBridge dep
```

On Android, the consumer's `android/settings.gradle.kts` (or root `build.gradle`) needs the GitHub Packages Maven repo:

```kotlin
dependencyResolutionManagement {
  repositories {
    google()
    mavenCentral()
    maven {
      url = uri("https://maven.pkg.github.com/deep-voice-ai/dvai-bridge")
      credentials {
        username = providers.gradleProperty("gpr.user").orNull
            ?: System.getenv("GITHUB_USER")
        password = providers.gradleProperty("gpr.token").orNull
            ?: System.getenv("GITHUB_TOKEN")
      }
    }
  }
}
```

Then in Dart:

```dart
import 'package:dvai_bridge/dvai_bridge.dart';
```

## 5. Versioning

3F ships under the `2.x.y` line. Phase 3E was tagged at `v2.2.0`; **Phase 3F is `v2.3.0`** (minor bump — additive). The Phase 3D Android umbrella AAR also bumps to 2.3.0 for build-graph consistency (no source changes; just a republish to align the `dvaiBridgeVersion` Gradle property). The Phase 3C iOS umbrella stays at 2.2 (no source changes; pod version pin in the Flutter podspec uses `'~> 2.2'` to allow patches).

Once 3G (.NET) follows it bumps to 2.4.0; 3H (docs/launch) is editorial only.

The Dart `pubspec.yaml` `version:` field follows pub semver — `2.3.0`. The `dvai_bridge` package version is bumped in lockstep with the rest of the family for the user's "easy mental model" (one number across all platforms).

## 6. Open questions (decided)

Per the project's "no deferrals" rule, every open question is resolved here:

1. **Plugin pattern: unified vs federated?** → **Unified.** Only iOS + Android are in scope for 3F. There's no third-party platform impl planned, and a federated split costs three packages, three pubspec versions, three publish flows, and a `_platform_interface` with a `MethodChannel`-based default impl just to support a hypothetical alternate. If/when desktop arrives, splitting then is straightforward (the unified package becomes the iOS+Android federated impl + a new app-facing facade).

2. **Channel layer: Pigeon vs MethodChannel vs FFI?** → **Pigeon (26.3.4).**
   | Option         | Type safety | Codegen | Async   | EventChannel | Verdict       |
   |----------------|-------------|---------|---------|--------------|---------------|
   | MethodChannel  | none (Map<String, dynamic>) | hand-written | manual | hand-written | rejected — error-prone |
   | Pigeon         | full (typed Dart/Swift/Kotlin)  | one CLI step | `@async` | `@EventChannelApi` (since 22.7) | **chosen** |
   | dart:ffi       | C ABI only  | bindgen | manual  | n/a          | rejected — wrong layer (we call Swift/Kotlin classes, not C funcs) |

   Pigeon parallels the React Native TurboModule codegen pattern from 3E — same "spec-first, native impl" mental model. The implementer writes a small Dart spec; the generator emits Dart bindings + Swift protocol + Kotlin interface. Errors caught at compile time on all three sides.

3. **Distribution: pub.dev vs git dep vs self-hosted pub?** → **pub.dev (public).** Flutter consumers expect this; git deps lack version constraints; self-hosted pub is operationally heavy. The asymmetry vs the rest of the family is documented in §4.1.

4. **Reactive state: `Stream<DVAIBridgeState>` vs `ChangeNotifier` vs `ValueNotifier`?** → **`Stream<DVAIBridgeState>`.** Streams compose with every modern Flutter state-management library (Riverpod `StreamProvider`, Bloc `BlocProvider`, `StreamBuilder`) and degrade gracefully to `ChangeNotifier` in 4 lines if a consumer prefers Provider. `ChangeNotifier` is `package:flutter`-coupled (it's in `flutter/foundation.dart`), and `ValueNotifier<DVAIBridgeState>` would force us to have a sentinel "no state yet" value or nullable wrap — uglier than the Stream's natural "no event yet → no listener notification yet" semantics.

5. **Min Flutter version?** → **Flutter 3.39+** (current stable 3.41.5 minus two minor versions). Pigeon 26 needs Dart 3.9 which lands with Flutter 3.41, but the Dart 3.7 floor on consumer apps is still buildable against the channel-only generated code (Pigeon's runtime is generated, not consumed). Setting the floor at 3.39 gives consumers headroom while the Pigeon-on-Dart-3.7 generated code still runs. Codify: `environment.flutter: '>=3.39.0'`, `environment.sdk: '>=3.7.0 <4.0.0'`. CI runs against 3.41.5 and 3.39.x.

6. **Min Dart version?** → **Dart 3.7+** (matches the Flutter 3.39 bundled Dart). The `pigeon` dev-dependency requires Dart 3.9 to run the codegen, but consumers don't run pigeon — they consume the generated `messages.g.dart`, which is plain Dart and works on 3.7+.

7. **Kotlin / AGP versions on the Flutter side?** → **Kotlin 2.1.x (matches Phase 3D), AGP 8.7.x for the plugin module.** Flutter 3.41's plugin templates don't yet support AGP 9; pin to AGP 8.7 (latest stable in the 8.x line that still works with Flutter's plugin Gradle helpers) until Flutter 3.44+ ships first-class AGP 9 support. The consumer app may use AGP 9.2 (matches Phase 3D) — Gradle resolves the plugin module's AGP 8.7 toolchain transparently. Note this asymmetry in the README.

8. **iOS deployment target?** → **iOS 15.1** (matches Phase 3C; Flutter 3.41's floor of iOS 13 is more permissive but our SDK already requires 15.1).

9. **Pigeon Swift `actor` support?** → Pigeon does not generate `actor` types directly (as of 26.3.4); it generates Swift `protocol`s with completion-handler-style methods. The plugin impl wraps `await DVAIBridge.shared.start(...)` inside a `Task { ... }` and bridges to the completion handler. This is identical to the pattern in the iOS / Capacitor plugin's existing `CAPPlugin` calls — no surprise.

10. **Codegen output committed or generated at build time?** → **Generated at build time, gitignored.** `dart run pigeon --input pigeons/messages.dart` runs as a `pre_build` step (a `Makefile` target + a `dart run` invocation in `melos`-style scripts). CI runs it before `flutter analyze` / `flutter test`. Same convention as RN's TurboModule codegen.

## 7. References

- Phase 3C iOS SDK spec: [docs/superpowers/specs/2026-04-26-phase3c-ios-native-sdk-design.md](2026-04-26-phase3c-ios-native-sdk-design.md)
- Phase 3D Android SDK spec: [docs/superpowers/specs/2026-04-27-phase3d-android-native-sdk-design.md](2026-04-27-phase3d-android-native-sdk-design.md)
- Phase 3E React Native spec: [docs/superpowers/specs/2026-04-27-phase3e-react-native-module-design.md](2026-04-27-phase3e-react-native-module-design.md)
- Phase 3 foundation spec: [docs/superpowers/specs/2026-04-26-phase3-foundation-design.md](2026-04-26-phase3-foundation-design.md)
- Flutter 3.41 release notes: https://docs.flutter.dev/release/release-notes/release-notes-3.41.0
- Flutter supported platforms (iOS 13+, Android API 24+): https://docs.flutter.dev/reference/supported-platforms
- Pigeon package (latest 26.3.4): https://pub.dev/packages/pigeon
- Pigeon EventChannel docs: https://pub.dev/packages/pigeon (search "EventChannelApi")
- Existing iOS DVAIBridge SDK: `packages/dvai-bridge-ios/`
- Existing Android DVAIBridge SDK: `packages/dvai-bridge-android/`
- pub.dev publishing guide: https://dart.dev/tools/pub/publishing
- Federated plugin guide (rejected for 3F): https://docs.flutter.dev/packages-and-plugins/developing-packages#federated-plugins
