# Testing

Phase 1 introduces three native plugins backed by handler-parity tests
in three languages (TS / Swift / Kotlin) plus a small set of
instrumented and real-model jobs. This page covers how to run each
layer locally and how the same layers map to CI.

## Layer 1 — TS workspace (vitest)

Runs everywhere — the inner-loop suite for any change touching the
shared shim, transports, or fixture-driven handlers.

```bash
pnpm test --run                           # all packages
pnpm test --run -- transport-fixtures      # narrow by name
pnpm --filter @dvai-bridge/core test       # one package
```

The suite is **fixture-driven**: shared canned-input/canned-output JSON
lives at `fixtures/transport-fixtures.json`, plus binary samples under
`fixtures/audio/` and `fixtures/images/`. The Swift and Kotlin suites
load the same JSON, which is how cross-language parity stays honest.

HTTP transport tests use [MSW](https://mswjs.io) to mock the in-process
fetch surface. When you add a new fixture, add a corresponding
parity assertion in each language's handler test.

## Layer 2 — iOS XCTest

The iOS plugins use Swift Package Manager and ship test targets
alongside the production target:

```
packages/dvai-bridge-capacitor-llama/ios/
  ├─ Package.swift
  ├─ Sources/DVAICapacitorLlama/
  └─ Tests/DVAICapacitorLlamaTests/
```

Three ways to run, depending on where you sit:

**On the Mac directly:**

```bash
# From the package root.
xcodebuild test \
  -scheme DVAICapacitorLlama \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.5'
# Or, when no simulator is required for a pure-logic test:
swift test
```

**Via the SSH-to-Mac wrapper from a Windows / Linux dev box:**

```bash
pwsh -File scripts/mac-build.ps1 -Action test -Target capacitor-llama
pwsh -File scripts/mac-build.ps1 -Action test -Target capacitor-foundation
pwsh -File scripts/mac-build.ps1 -Action test -Target capacitor-mediapipe
```

This `git pull`s on the Mac, runs the `mac-side-test.sh` helper, and
streams stdout / stderr back. See
[Mac remote builds](./mac-remote-builds.md) for setup.

**In CI:** the `test-ios-{llama,foundation,mediapipe}.yml` workflows run
the same `xcodebuild test` invocation on a self-hosted ARM64 macOS
runner.

## Layer 3 — Android JVM (Gradle)

Robolectric-backed JUnit 5 tests, runnable on any JDK 21 host without an
emulator:

```bash
cd packages/dvai-bridge-capacitor-llama/android
./gradlew test
```

Same pattern for `dvai-bridge-capacitor-mediapipe/android`. JNI / native
load is mocked at this layer — handler logic, port-fallback, JSON
shapes, and lifecycle wiring are all verified here.

In CI: `test-android-{llama,mediapipe}-jvm.yml` on `ubuntu-latest`.

## Layer 4 — Android instrumented (emulator)

Anything that needs the real `MediaCodec` / `MediaExtractor` lives in
`src/androidTest/`. Currently this is just `AudioDecoderInstrumentedTest`.

```bash
cd packages/dvai-bridge-capacitor-llama/android
./gradlew connectedAndroidTest        # requires running emulator/device
```

In CI: `test-android-instrumented.yml` boots an API-34 emulator via
[`reactivecircus/android-emulator-runner@v2`](https://github.com/ReactiveCircus/android-emulator-runner)
on `ubuntu-latest`. It runs only when `audio-decoder` paths or audio
fixtures change — the emulator is the slowest job in CI.

## Layer 5 — real-model smoke (slow tier)

`smoke-real-models.yml` runs nightly + on `workflow_dispatch`. It
downloads a small public GGUF (Tier 1 in [tested-models.md](../guide/tested-models.md)),
calls `start()`, makes one round-trip against `/v1/chat/completions`,
and verifies `200` + non-empty `choices[0].message.content`. iOS uses
the self-hosted ARM64 macOS runner; Android uses an emulated runner.

What we deliberately don't verify here: output quality, latency, token
counts. Mechanics only.

## Adding a fixture

1. Drop the new JSON entry into `fixtures/transport-fixtures.json` (and
   any binary into `fixtures/audio/` or `fixtures/images/`).
2. Update `fixtures/transport-fixtures.schema.json` if you added a new
   shape; CI's `fixtures-shape` test enforces this.
3. Add the matching parity assertion in:
   - TS — `packages/dvai-bridge-core/src/__tests__/`.
   - Swift — relevant `Tests/...HandlersTest.swift`.
   - Kotlin — relevant `src/test/.../HandlersTest.kt`.
4. Run all three before committing — see
   [Handler parity](./handler-parity.md) for the discipline rule.

## The `mock-bridge` testing pattern

Each backend plugin defines a small mock bridge (`MockLlamaBridge` in
Swift, the Kotlin equivalent) that returns canned chunk streams without
touching real native libraries. This lets Layer 2 / 3 tests cover the
HTTP routing, SSE framing, and content-parts translation in isolation
from llama.cpp / MediaPipe / Foundation Models.

When you add behavior that crosses the bridge boundary (e.g. a new
content-part type, a new error path), wire the mock to emit the
representative output and assert against it. Real-bridge coverage stays
in Layer 5.
