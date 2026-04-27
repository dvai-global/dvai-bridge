# Contributing: Flutter SDK

This page covers the local build + test loop for contributors working on
the Flutter slice. For end-user docs see
[flutter-sdk.md](/guide/flutter-sdk).

The Flutter plugin (`dvai_bridge`) wraps the iOS + Android native SDKs
behind a Pigeon-generated platform-channel API. There is no
hand-rolled FFI; Pigeon owns both the Dart and the native (Swift /
Kotlin) sides of the channel.

## Prerequisites

- **Flutter 3.41+** (latest stable) and **Flutter 3.39+** (floor) —
  CI exercises both. The package is developed against 3.41.5.
- **Dart 3.7+** — bundled with Flutter; no separate install.
- **Pigeon 26.3+** — declared as a `dev_dependency` in
  `pubspec.yaml`. Pulled by `flutter pub get`.
- **iOS toolchain** — Xcode 16+, CocoaPods, iOS 18.5 simulator. See
  [contributing-ios.md](./contributing-ios.md).
- **Android toolchain** — JDK 23, Android SDK 36, **AGP 8.7.3** (see
  the AGP-pin note below). See
  [contributing-android.md](./contributing-android.md).

## Build + test loop

```bash
cd packages/dvai-bridge-flutter

# Pull deps + run the Pigeon codegen before any test pass.
flutter pub get
dart run pigeon --input pigeons/messages.dart

# Static analysis + tests.
flutter analyze
flutter test
```

The repo also ships an npm-style script alias mirror in `package.json`
for monorepo tooling — `pnpm --filter @dvai-bridge/flutter build` runs
`flutter pub get` and the Pigeon command together. Either path is fine;
the `dart run pigeon ...` form is the source of truth.

### Why AGP 8.7.3 (and not 9.x)

The Flutter plugin module pins **AGP 8.7.3** in
`packages/dvai-bridge-flutter/android/build.gradle`, intentionally
behind the umbrella's AGP 9.2 pin. Flutter 3.41's plugin Gradle
templates don't yet support AGP 9 — switching breaks the plugin's
embedding pipeline. Consumer apps can use AGP 9.2 in their own
`android/app/build.gradle`; AGP versions can differ between a Flutter
plugin and the consumer app, and Gradle resolves the asymmetry
correctly. Revisit when Flutter ships AGP-9-ready plugin templates
(tracked in the package's README "AGP asymmetry" note).

## Common breakage modes

- **Stale Pigeon output** — if you edit `pigeons/messages.dart` and
  forget to re-run codegen, `flutter test` will fail with type
  mismatches against the regenerated native bindings. Re-run
  `dart run pigeon --input pigeons/messages.dart`.
- **`flutter pub get` resolves to the wrong Pigeon major** — the
  pubspec pins `pigeon: ^26.3.4`. If a transitive constraint pulls a
  different major, run `flutter pub upgrade --major-versions` and
  inspect the resulting `pubspec.lock`.
- **iOS plugin doesn't link** — `cd example/ios && pod install` after
  any Pigeon regen, same as RN.
- **Android example app fails with AGP-version errors** — the
  consumer app uses its own AGP pin (independent of the plugin's
  8.7.3). If the example app is on AGP 9.2 and starts breaking, check
  whether Flutter has updated its plugin templates yet.
- **`flutter analyze` fails after a Dart SDK upgrade** — the floor
  is `sdk: ">=3.7.0 <4.0.0"` in `pubspec.yaml`. Check that your local
  Flutter ships a Dart inside that range.

## Related

- [Flutter SDK guide](/guide/flutter-sdk) — user-facing API.
- [contributing-ios.md](./contributing-ios.md) — the iOS half of the
  plugin's native build.
- [contributing-android.md](./contributing-android.md) — the Android
  half (note the AGP-pin asymmetry).
- [Handler parity](./handler-parity.md) — Pigeon channel changes must
  stay aligned with the underlying Swift / Kotlin handlers.
