# Contributing: Android Native SDK

This page covers the local build + test loop for contributors working on
the Android slice. For end-user docs see
[android-native-sdk.md](/guide/android-native-sdk).

The Android side ships as **five separate Gradle modules**, each with
its own AAR coordinate on GitHub Packages. They build independently:

- `packages/dvai-bridge-android-shared-core` — handler-dispatch +
  HTTP-server + transport types.
- `packages/dvai-bridge-android-llama-core` — llama.cpp backend.
- `packages/dvai-bridge-android-mediapipe-core` — MediaPipe / Tasks-GenAI
  backend.
- `packages/dvai-bridge-android-litert-core` — LiteRT-LM backend (see
  [LiteRT-LM migration notes](./litert-lm-migration-notes.md)).
- `packages/dvai-bridge-android` — umbrella AAR that re-exports the
  four cores under a single `DVAIBridge` Kotlin object.

## Prerequisites

- **JDK 23** (Temurin / Zulu / Liberica all work). Set `JAVA_HOME` and
  ensure `java -version` reports 23.
- **Android SDK 36** with command-line tools. Set `ANDROID_HOME` (or
  `ANDROID_SDK_ROOT`). The Gradle `compileSdk 36` matches.
- **Gradle wrapper** auto-fetched per module — no system Gradle
  install required. AGP is pinned **9.2.0** in the cores + umbrella;
  the Flutter plugin keeps its own AGP 8.7.3 pin (see
  [contributing-flutter.md](./contributing-flutter.md) for why).
- **Kotlin 2.3.21** — bundled by the Gradle wrapper, no extra setup.
- **Android emulator (API 34)** — only required for instrumented
  tests. Robolectric / JVM tests run without it.

## Build + test loop

Each module is independent; pick the one you're touching.

```bash
cd packages/dvai-bridge-android-shared-core
./gradlew assemble test                    # JVM tests, Robolectric where needed

cd ../dvai-bridge-android-llama-core
./gradlew assemble test

cd ../dvai-bridge-android-mediapipe-core
./gradlew assemble test

cd ../dvai-bridge-android-litert-core
./gradlew assemble test

# Umbrella — pulls the four cores from `mavenLocal()` in dev.
cd ../dvai-bridge-android
./gradlew assemble test
```

For a cross-module dev loop (umbrella consumes the four cores via Maven
coords), publish locally first:

```bash
bash scripts/android-publish-local.sh    # publishes all five to ~/.m2
cd packages/dvai-bridge-android && ./gradlew assemble test
```

Instrumented tests on a connected emulator / device:

```bash
./gradlew connectedAndroidTest    # any module with src/androidTest/
```

## Common breakage modes

- **Stale JNI libs after a llama.cpp bump** — the `*.so` files under
  `src/main/jniLibs/` survive `assemble` but a clean shakes them out.
  Run `./gradlew clean` and re-publish.
- **NDK version mismatch** — the cores don't pin an NDK; Gradle uses
  whatever matches the AGP default. If you see linker errors, install
  the NDK version that AGP 9.2 expects through `sdkmanager
  "ndk;<version>"`.
- **Gradle daemon hangs** — kill it with `./gradlew --stop` and retry.
  Most often happens when Kotlin compiler memory limits get exceeded
  during parallel module builds.
- **`mavenLocal()` lookups fail for the umbrella** — the four cores
  haven't been published yet. Re-run
  `bash scripts/android-publish-local.sh`.
- **`compileSdk 36` not found** — install via
  `sdkmanager "platforms;android-36"`.

## Related

- [Android Native SDK guide](/guide/android-native-sdk) — user-facing
  API.
- [LiteRT-LM migration notes](./litert-lm-migration-notes.md) — the
  research artifact behind the `litert-core` module's backend choice.
- [Testing](./testing.md) — full layer-by-layer test guide, including
  the Android JVM (Layer 3) and instrumented (Layer 4) layers.
- [Handler parity](./handler-parity.md) — why the Kotlin handlers must
  stay byte-for-byte aligned with the Swift and TS suites.
