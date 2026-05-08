# Flutter SDK (`dvai_bridge`)

`dvai_bridge` is the Flutter plugin that wraps the
[`@dvai-bridge/ios`](./ios-native-sdk.md) and
[`@dvai-bridge/android`](./android-native-sdk.md) native SDKs behind a
shared Dart API. Drop it into a Flutter app, call `DVAIBridge.instance
.start(...)`, then point any OpenAI-compatible Dart HTTP client at the
returned `baseUrl`.

If you're building with React Native, use
[`@dvai-bridge/react-native`](./react-native-sdk.md) instead.
SwiftUI / Compose apps have direct guides at
[iOS Native SDK](./ios-native-sdk.md) and
[Android Native SDK](./android-native-sdk.md).

## Requirements

- **Flutter ≥ 3.39** (Dart ≥ 3.7). The package is developed against
  Flutter 3.41.5 (Dart 3.11) and CI exercises both the latest stable and
  the 3.39 floor.
- **iOS 15.1+ link target**, **Android `minSdk 24`**. The underlying
  `DVAIBridge` umbrella raises the iOS minimum to **18.1** at runtime.

## Install

`dvai_bridge` is **published to pub.dev** (the only family member that
isn't on GitHub Packages):

```bash
flutter pub add dvai_bridge
```

That fetches the Dart facade. The native bridge layers compile during
the consumer's `pod install` (iOS) and Gradle sync (Android), pulling the
underlying SDKs from CocoaPods Trunk and GitHub Packages Maven respectively.

::: tip Family asymmetry
The Flutter plugin lives on **pub.dev (public)**; every other family
member ships through GitHub Packages (private). The Flutter plugin's
runtime dependencies (`DVAIBridge` Swift package, `co.deepvoiceai:dvai-bridge`
AAR) are still distributed via the family's normal channels — you'll
need a GitHub PAT for the Android Maven repo even though the Dart
package itself is public. See
[migration v2.2 → v2.3](../migration/v2.2-to-v2.3.md) for the full
distribution table.
:::

### iOS — Podfile

The plugin's autolinking pulls in `dvai_bridge.podspec`, which depends
on the `DVAIBridge` umbrella pod (Phase 3C v2.2). Make sure the iOS
deployment target meets the floor:

```ruby
# ios/Podfile
platform :ios, '15.1'

target 'Runner' do
  use_frameworks!
  use_modular_headers!
  flutter_install_all_ios_pods File.dirname(File.realpath(__FILE__))
end
```

Then:

```bash
cd ios
pod install
```

::: warning MLX under CocoaPods
Flutter consumers always go through CocoaPods (Flutter doesn't auto-route
to SwiftPM). Two backends are unavailable under that build path:

- **`mlx`** — `mlx-swift-lm`'s transitive Swift packages don't publish
  CocoaPods specs. Selecting it throws
  `DVAIBridgeError` with `kind == DVAIBridgeErrorKind.backendUnavailable`.
- **`foundation`** — Apple's `FoundationModels` framework triggers
  private-framework autolink directives CocoaPods consumers cannot link.

If you need either backend from a Flutter app, replace the pod entry with
a path-based SwiftPM checkout in your Podfile:

```ruby
pod 'DVAIBridge', :path => '../path/to/dvai-bridge-ios/ios'
```

That uses the SwiftPM-flavoured source tree (with the MLX +
FoundationModels imports compiled in). This is the same caveat the
[iOS Native SDK guide](./ios-native-sdk.md#cocoapods-asymmetries) and
[React Native SDK guide](./react-native-sdk.md) document.
:::

### Android — Gradle

The plugin's `build.gradle` depends on `co.deepvoiceai:dvai-bridge:3.0.0`,
hosted on **GitHub Packages Maven**. The consumer app needs three pieces
of config:

#### 1. Add the GitHub Packages Maven repo to `settings.gradle.kts`

```kotlin
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        maven {
            url = uri("https://maven.pkg.github.com/Westenets/dvai-bridge")
            credentials {
                username = providers.gradleProperty("gpr.user").orNull
                    ?: System.getenv("GITHUB_ACTOR")
                password = providers.gradleProperty("gpr.key").orNull
                    ?: System.getenv("GITHUB_TOKEN")
            }
        }
    }
}
```

#### 2. Provide a token

Per-developer in `~/.gradle/gradle.properties`:

```properties
gpr.user=your-github-username
gpr.key=ghp_classic_token_with_read_packages_scope
```

GitHub Packages requires authentication even for public reads; the
minimum scope is `read:packages`.

#### 3. Initialize the bridge from `Application.onCreate()` (optional)

```kotlin
import android.app.Application
import co.deepvoiceai.bridge.DVAIBridge

class MainApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        DVAIBridge.init(this)
    }
}
```

The plugin re-runs `DVAIBridge.init(applicationContext)` defensively on
plugin attach, so this step is optional but recommended — it guarantees
the bridge is ready before the first Dart-side `start()` invocation.

::: tip AGP asymmetry
The plugin module pins **AGP 8.7.x** (Flutter 3.41's plugin Gradle
templates don't yet support AGP 9). Your consumer app can use AGP 9.2
(matches the Phase 3D umbrella) — Gradle resolves the plugin's compile
classpath independently. No action required.
:::

## Quickstart

```dart
import 'package:dvai_bridge/dvai_bridge.dart';

Future<void> bootInference() async {
  final BoundServer server = await DVAIBridge.instance.start(
    const StartOptions(
      backend: BackendKind.auto,
      modelPath: '/path/to/Llama-3.2-1B-Instruct.Q4_K_M.gguf',
      contextSize: 2048,
      threads: 4,
    ),
  );
  print(server.baseUrl); // http://127.0.0.1:38883/v1
  print(server.backend); // BackendKind.llama
}
```

Hit it with any OpenAI-compatible client (here, `package:http`):

```dart
import 'dart:convert';
import 'package:http/http.dart' as http;

final res = await http.post(
  Uri.parse('${server.baseUrl}/chat/completions'),
  headers: const <String, String>{'Content-Type': 'application/json'},
  body: jsonEncode(<String, dynamic>{
    'model': server.modelId,
    'messages': <Map<String, String>>[
      <String, String>{'role': 'user', 'content': 'Hello'},
    ],
  }),
);
final Map<String, dynamic> json = jsonDecode(res.body) as Map<String, dynamic>;
```

When you're done:

```dart
await DVAIBridge.instance.stop();
```

## Backends

`BackendKind` is the **union** of every backend supported by either
platform. The Dart facade rejects requests for the wrong-platform backend
eagerly with a `DVAIBridgeError(kind: backendUnavailable)` before the
platform-channel call.

| `BackendKind`     | Engine                       | Model format                                | iOS | Android | Notes |
|-------------------|------------------------------|---------------------------------------------|:---:|:-------:|-------|
| `BackendKind.auto`        | Resolve at runtime           | Inferred from `modelPath`                   |  ✓  |    ✓    | See per-platform auto rules. |
| `BackendKind.llama`       | llama.cpp (Metal / Vulkan)   | GGUF                                        |  ✓  |    ✓    | Broadest model coverage. |
| `BackendKind.foundation`  | Apple Foundation Models      | (no file)                                   |  ✓  |    —    | iOS 26+. **SwiftPM-only** — see CocoaPods caveat above. |
| `BackendKind.coreml`      | CoreML / Apple Neural Engine | `.mlmodelc` / `.mlpackage`                  |  ✓  |    —    | iOS 18+. Experimental — see iOS guide. |
| `BackendKind.mlx`         | `mlx-swift-lm`               | HuggingFace Hub id                          |  ✓  |    —    | Apple-Silicon only. **SwiftPM-only**. |
| `BackendKind.mediapipe`   | LiteRT-LM (post-Phase 3B)    | `.task` / `.litertlm`                       |  —  |    ✓    | Vision support via `visionEnabled`. |
| `BackendKind.litert`      | Bare LiteRT (TFLite successor) | `.tflite` / `.litertlm`                   |  —  |    ✓    | New in Phase 3D. Pure-Kotlin BPE tokenizer. |

## Reactive state — `Stream<DVAIBridgeState>`

`DVAIBridge.instance.stateStream` is a broadcast `Stream` that emits a
`DVAIBridgeState` on every backend lifecycle transition. Idiomatic
Flutter consumers compose it with `StreamBuilder`, Riverpod's
`StreamProvider`, or Bloc.

```dart
import 'package:flutter/material.dart';
import 'package:dvai_bridge/dvai_bridge.dart';

class StatusBar extends StatelessWidget {
  const StatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DVAIBridgeState>(
      stream: DVAIBridge.instance.stateStream,
      initialData: DVAIBridgeState.idle,
      builder: (BuildContext context, AsyncSnapshot<DVAIBridgeState> snap) {
        final DVAIBridgeState state = snap.data ?? DVAIBridgeState.idle;
        if (!state.isReady) {
          final ProgressEvent? prog = state.lastProgress;
          if (prog != null && prog.kind == ProgressKind.progress) {
            return Text('Loading ${prog.percent?.toStringAsFixed(0) ?? "?"}%');
          }
          return const CircularProgressIndicator();
        }
        return Text('Server: ${state.baseUrl} (${state.backend?.name})');
      },
    );
  }
}
```

### Riverpod

```dart
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:dvai_bridge/dvai_bridge.dart';

@riverpod
Stream<DVAIBridgeState> dvaiBridgeState(DvaiBridgeStateRef ref) {
  return DVAIBridge.instance.stateStream;
}
```

### Bloc

```dart
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:dvai_bridge/dvai_bridge.dart';

class BridgeCubit extends Cubit<DVAIBridgeState> {
  BridgeCubit() : super(DVAIBridgeState.idle) {
    DVAIBridge.instance.stateStream.listen(emit);
  }
}
```

## Progress events

The same source feeds a `Stream<ProgressEvent>` if you need raw
fine-grained events:

```dart
final StreamSubscription<ProgressEvent> sub =
    DVAIBridge.instance.progressStream.listen((ProgressEvent event) {
  switch (event.kind) {
    case ProgressKind.started:
      print('${event.phase.name} started');
      break;
    case ProgressKind.progress:
      print('${event.phase.name} ${event.percent ?? "?"}%');
      break;
    case ProgressKind.completed:
      print('${event.phase.name} done');
      break;
    case ProgressKind.failed:
      print('${event.phase.name} failed: ${event.errorMessage}');
      break;
  }
});

// Later:
await sub.cancel();
```

Every event has a `kind` and a `phase` discriminator (see
[the Dart enums](https://pub.dev/documentation/dvai_bridge/latest/dvai_bridge/ProgressKind.html)
for the full set). Both iOS and Android emit the same shape.

## Model download

```dart
final DownloadResult result = await DVAIBridge.instance.downloadModel(
  const DownloadOptions(
    url: 'https://huggingface.co/example/model/resolve/main/model.gguf',
    sha256: 'abc123…',
  ),
);
print('${result.path} (${result.sizeBytes} bytes)');
```

The download uses the platform-native downloader (`URLSession` on iOS,
OkHttp on Android), streams straight to disk, and verifies SHA-256 on
completion. Failing checksums delete the partial file and throw
`DVAIBridgeError` with `kind: DVAIBridgeErrorKind.checksumMismatch`.

## Errors

Every public method that can fail throws a `DVAIBridgeError` (a Dart
sealed class — `switch` on it for exhaustive handling):

| `kind`                  | When                                                                        |
|-------------------------|-----------------------------------------------------------------------------|
| `alreadyStarted`        | `start()` called twice without `stop()`.                                    |
| `notStarted`            | A method that requires `start()` was called before it.                      |
| `configurationInvalid`  | Bad `StartOptions` (e.g. unsupported `modelPath` extension under `auto`).    |
| `modelLoadFailed`       | Backend rejected the model file or tokenizer.                               |
| `backendUnavailable`    | Backend can't run on this platform / build (CocoaPods `mlx`, Android `coreml`). |
| `backendError`          | Generic backend failure (HTTP server bind, inference exception).            |
| `checksumMismatch`      | `downloadModel` SHA-256 didn't match.                                       |
| `downloadFailed`        | `downloadModel` networking failure.                                         |

```dart
try {
  await DVAIBridge.instance.start(
    const StartOptions(backend: BackendKind.foundation),
  );
} on DVAIBridgeError catch (err) {
  if (err.kind == DVAIBridgeErrorKind.backendUnavailable) {
    // Fall back to llama
    await DVAIBridge.instance.start(
      const StartOptions(backend: BackendKind.llama, modelPath: '...'),
    );
  } else {
    rethrow;
  }
}
```

Or with sealed-class exhaustiveness:

```dart
try {
  await DVAIBridge.instance.start(opts);
} on AlreadyStartedError catch (err) {
  // err.backend / err.baseUrl available
} on BackendUnavailableError catch (err) {
  // err.backend available
} on ChecksumMismatchError catch (err) {
  // err.expected / err.got available
}
```

## Distributed inference (`offload`) — v3.0+

`dvai_bridge` v3.0+ surfaces the v3.0 distributed-inference configuration.
Pass an `OffloadConfig` to `start()` to enable LAN / internet peer
discovery and request offload when local capability is insufficient. See
the [Distributed Inference guide](./distributed-inference.md) for the
full feature description.

```dart
final BoundServer server = await DVAIBridge.instance.start(
  const StartOptions(
    backend: BackendKind.auto,
    modelPath: '/path/to/model.gguf',
    offload: OffloadConfig(
      enabled: true,
      discoverLAN: true,
      minLocalCapability: 10,
      rendezvousUrl: 'wss://rendezvous.myapp.com', // optional, internet path
    ),
  ),
);
```

The `onPairingRequest` callback from the JS-side `OffloadConfig` cannot
cross the Pigeon channel, so Dart consumers receive inbound pairing
requests via the `pairingRequests` `Stream<PairingRequest>` and respond
by calling `PairingRequest.respond(approved: ...)`:

```dart
final StreamSubscription<PairingRequest> sub =
    DVAIBridge.instance.pairingRequests.listen((req) async {
  final bool approved = await myUiConfirm(req.peerDeviceName);
  await req.respond(approved: approved);
});

// Tear down on widget dispose:
await sub.cancel();
```

Without a registered listener, inbound pairing requests are denied
after the request's `expiresAt` deadline.

## Reference

- [iOS Native SDK](./ios-native-sdk.md) — the underlying Swift surface.
- [Android Native SDK](./android-native-sdk.md) — the underlying Kotlin
  surface.
- [Backends comparison](./backends.md) — when to pick which engine.
- [MLX Backend](./mlx-backend.md) — the iOS-only MLX path
  (SwiftPM-only).
- [Migration v2.2 → v2.3](../migration/v2.2-to-v2.3.md) — Flutter plugin
  rollout context.
