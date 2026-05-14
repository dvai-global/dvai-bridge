# License setup — Flutter

You added `dvai_bridge` to your `pubspec.yaml` and want to ship a
release build. Here's the licensing path.

## TL;DR

Drop `dvai-license.jwt` into your app's `assets/` directory and
register it in `pubspec.yaml`. At `DVAIBridge.instance.start(...)`
time, the SDK loads it via `rootBundle`, verifies the ES256 signature
offline, and unlocks production behaviour. In `flutter run --debug`
the SDK ignores license problems.

## Where the file goes

Add the file under `assets/`:

```
my_app/
  assets/
    dvai-license.jwt
  pubspec.yaml
```

Register the asset in `pubspec.yaml`:

```yaml
flutter:
  assets:
    - assets/dvai-license.jwt
```

Alternative locations the SDK also checks (in priority order):

1. Inline JWT via `StartOptions(licenseToken: "...")`.
2. Explicit path via `StartOptions(licenseKeyPath: ...)` — a path
   under `getApplicationDocumentsDirectory()` is typical for tokens
   downloaded after install.
3. `assets/dvai-license.jwt` via `rootBundle` (auto-discovered).

## Code: with vs. without

Default (license bundled in `assets/`):

```dart
import 'package:dvai_bridge/dvai_bridge.dart';

final bound = await DVAIBridge.instance.start(StartOptions(
  backend: BackendKind.llama,
  modelPath: modelFile.path,
));

print(bound.baseUrl);            // http://127.0.0.1:38883/v1
print(bound.licenseStatus);      // LicenseStatus.commercial(licensee: "Acme", ...)
```

With an inline JWT (loaded from `flutter_secure_storage`):

```dart
final token = await secureStorage.read(key: 'dvai_license_jwt');

final bound = await DVAIBridge.instance.start(StartOptions(
  backend: BackendKind.llama,
  modelPath: modelFile.path,
  licenseToken: token,
));
```

With an explicit file path:

```dart
final docs = await getApplicationDocumentsDirectory();
final licensePath = '${docs.path}/dvai-license.jwt';

final bound = await DVAIBridge.instance.start(StartOptions(
  backend: BackendKind.llama,
  modelPath: modelFile.path,
  licenseKeyPath: licensePath,
));
```

::: tip Native license fields land in v3.3
In v3.2.x, the Flutter SDK ships without `licenseToken` /
`licenseKeyPath` on `StartOptions`. Pure Flutter apps in v3.2 ship
under a "dev preview" allowance. Native Flutter validation arrives
in v3.3 — pin to v3.3+ to enforce on Flutter.
:::

## What happens without a license

In release builds (`flutter build apk`, `flutter build ipa`),
`start(...)` throws `DVAIBridgeError.licenseRequired`:

```dart
try {
  final bound = await DVAIBridge.instance.start(...);
} on DVAIBridgeError catch (e) {
  if (e.kind == DVAIBridgeErrorKind.licenseRequired) {
    // e.message is a multi-line string with resolution steps.
    debugPrint(e.message);
    showDialog(...);
  }
}
```

## Testing locally without a license

`flutter run --debug` automatically enables dev mode. The SDK
detects debug mode via `kDebugMode` (which Flutter sets via
`assert(...)` inlining).

To force dev mode explicitly inside a profile / release build:

```dart
const bool kForceDev = bool.fromEnvironment('DVAI_FORCE_DEV', defaultValue: false);
```

Pass at build time:

```bash
flutter build apk --dart-define=DVAI_FORCE_DEV=true
```

To rehearse production behaviour in a debug build:

```bash
flutter run --dart-define=DVAI_FORCE_PROD=true
```

## When validation fails

| Error reason fragment | What's wrong | Fix |
| --- | --- | --- |
| `asset not found` | `assets/dvai-license.jwt` missing from `pubspec.yaml` | Add the asset entry |
| `signature did not verify` | Wrong key or tampered | Re-download from your licensor |
| `does not authorise platform "flutter"` | License missing `"flutter"` in `platforms` | Re-issue covering Flutter |
| `audience entries ... do not match` | Bundle id / package name doesn't match | Re-issue with the right ids, or use a wildcard |
| `expired` | Past `exp` | Renew |

The runtime audience on Flutter is the platform-specific app id:
`CFBundleIdentifier` on iOS, `applicationId` on Android. Most
licenses include both plus a `"*"` fallback.

## See also

- [License setup index](./index)
- [Flutter SDK](/guide/flutter-sdk) — full SDK reference.
