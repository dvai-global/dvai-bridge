# React Native SDK (`@dvai-bridge/react-native`)

`@dvai-bridge/react-native` is the React Native TurboModule that wraps the
[`@dvai-bridge/ios`](./ios-native-sdk.md) and
[`@dvai-bridge/android`](./android-native-sdk.md) native SDKs behind a
shared TypeScript API. Drop it into a bare React Native app, call
`DVAIBridge.start(...)`, point any OpenAI-compatible RN HTTP client at the
returned `baseUrl`.

If you're building a Capacitor app, you don't need this page — see
[Native LLM (Capacitor)](./native-backend.md). If you're shipping a SwiftUI
or Compose app without RN, see the
[iOS Native SDK](./ios-native-sdk.md) or
[Android Native SDK](./android-native-sdk.md) guides instead.

## Requirements

- **React Native ≥ 0.77** (Bridgeless / TurboModule on by default).
  Older RN consumers should stay on Capacitor or pin to the legacy
  `@dvai-bridge/capacitor-*` packages.
- **Node ≥ 22** (for the build / test toolchain).
- **iOS 15.1+ link target**, **Android `minSdk 24`**. The underlying
  `DVAIBridge` umbrella raises the iOS minimum to **18.1** at runtime.

## Install

The package is published to GitHub Packages npm:

```bash
npm install @dvai-bridge/react-native --registry=https://npm.pkg.github.com
```

Add a `.npmrc` line so the resolution sticks:

```
@dvai-bridge:registry=https://npm.pkg.github.com
//npm.pkg.github.com/:_authToken=ghp_classic_token_with_read_packages_scope
```

(Tokens are managed at <https://github.com/settings/tokens>. Read-only
consumption needs only the `read:packages` scope.)

### iOS — `pod install`

The package's `react-native.config.js` autolinks the `DVAIBridgeNative`
pod. After installing the npm package:

```bash
cd ios
pod install
```

That pulls the `DVAIBridge` umbrella pod (Phase 3C v2.1) as a transitive
dependency. **CocoaPods consumers see two backend caveats:**

- **`mlx` backend** is unavailable under CocoaPods (mlx-swift-lm's
  transitive Swift packages don't publish CocoaPods specs). Selecting it
  throws `DVAIBridgeError` with `kind: "backendUnavailable"`.
- **`foundation` backend** is unavailable under CocoaPods (Apple's
  `FoundationModels` framework triggers private-framework autolink
  directives CocoaPods consumers cannot link).

If you need `mlx` or `foundation` from a React Native app, replace the
default pod entry in your Podfile with a path-based SwiftPM checkout:

```ruby
# Podfile
pod 'DVAIBridge', :path => '../node_modules/@dvai-bridge/ios'
```

…then run `pod install` again. The CocoaPods build still uses Swift
modules, but the SPM-only Swift code paths (with their MLX +
FoundationModels imports) compile because `:path` resolves to the
SwiftPM-flavored source tree. This is identical to the
[iOS Native SDK guide § CocoaPods asymmetries](./ios-native-sdk.md#cocoapods-asymmetries)
caveat.

### Android — Gradle

The package's autolinking config registers the Android module
automatically. The umbrella AAR (`co.deepvoiceai:dvai-bridge:4.0.0`) is
hosted on **Maven Central** — no token, no auth, nothing to set up.
React Native projects ship `mavenCentral()` in their default
`settings.gradle` (or `android/build.gradle`) repo list, so autolinking
will resolve the AAR automatically.

If you've stripped `mavenCentral()` out of your project's repo list,
add it back:

```kotlin
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}
```

#### Initialize the bridge from `Application.onCreate()` (optional)

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

The TurboModule re-runs `DVAIBridge.init(reactContext.applicationContext)`
defensively on every JS-side call, so this step is strictly optional —
it's the recommended path because it guarantees the bridge is ready before
the first `start()` invocation.

## Quickstart

```ts
import {
  DVAIBridge,
  BackendKind,
  useDVAIBridgeState,
} from "@dvai-bridge/react-native";

async function bootInference() {
  const server = await DVAIBridge.start({
    backend: BackendKind.Auto,
    modelPath: "/path/to/Llama-3.2-1B-Instruct.Q4_K_M.gguf",
    contextSize: 2048,
    threads: 4,
  });
  console.log(server.baseUrl); // "http://127.0.0.1:38883/v1"
  console.log(server.backend); // "llama" (auto-resolved from .gguf)
}
```

Hit it with any OpenAI-compatible client:

```ts
const res = await fetch(`${server.baseUrl}/chat/completions`, {
  method: "POST",
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({
    model: server.modelId,
    messages: [{ role: "user", content: "Hello" }],
  }),
});
const json = await res.json();
```

When you're done:

```ts
await DVAIBridge.stop();
```

## Backends

Cross-platform `BackendKind` is the **union** of every backend supported
by either platform. The TS facade rejects requests for the wrong-platform
backend eagerly with a `DVAIBridgeError(kind: "backendUnavailable")`
before the native round-trip.

| `BackendKind` | Engine                       | Model format                                | iOS | Android | Notes |
|---------------|------------------------------|---------------------------------------------|:---:|:-------:|-------|
| `Auto`        | Resolve at runtime           | Inferred from `modelPath`                   |  ✓  |    ✓    | See per-platform auto rules. |
| `Llama`       | llama.cpp (Metal / Vulkan)   | GGUF                                        |  ✓  |    ✓    | Broadest model coverage. |
| `Foundation`  | Apple Foundation Models      | (no file)                                   |  ✓  |    —    | iOS 26+. **SwiftPM-only** under iOS. |
| `CoreML`      | CoreML / Apple Neural Engine | `.mlmodelc` / `.mlpackage`                  |  ✓  |    —    | iOS 18+. Experimental — see iOS guide. |
| `MLX`         | mlx-swift-lm                 | HuggingFace Hub id                          |  ✓  |    —    | Apple-Silicon only. **SwiftPM-only**. |
| `MediaPipe`   | LiteRT-LM (post-Phase 3B)    | `.task` / `.litertlm`                       |  —  |    ✓    | Vision support via `visionEnabled`. |
| `LiteRT`      | Bare LiteRT (TFLite successor) | `.tflite` / `.litertlm`                   |  —  |    ✓    | New in Phase 3D. Pure-Kotlin BPE tokenizer. |

### Auto-resolution

| `modelPath`                       | iOS resolves to | Android resolves to |
|-----------------------------------|-----------------|---------------------|
| `*.gguf`                          | `Llama`         | `Llama`             |
| `*.task`                          | error           | `MediaPipe`         |
| `*.tflite` / `*.litertlm`         | error           | `LiteRT`            |
| `*.mlmodelc` / `*.mlpackage`      | `CoreML`        | error               |
| `nil` + iOS 26+                   | `Foundation`    | error               |
| `<owner>/<repo>` (HF id, no ext)  | error — pass `MLX` explicitly | error |

Pass an explicit `BackendKind` instead of `Auto` whenever the model file's
extension doesn't match the desired backend (e.g. an MLX checkpoint
identified by HuggingFace id).

## React hook: `useDVAIBridgeState`

```tsx
import { useDVAIBridgeState } from "@dvai-bridge/react-native";

function StatusBar() {
  const state = useDVAIBridgeState();
  if (!state.isReady) {
    return state.lastProgress?.kind === "progress" ? (
      <Text>Loading {state.lastProgress.percent ?? 0}%…</Text>
    ) : (
      <ActivityIndicator />
    );
  }
  return (
    <Text>
      Server: {state.baseUrl} ({state.backend})
    </Text>
  );
}
```

The hook subscribes to the underlying `NativeEventEmitter` and re-renders
on every progress event. It's polling-free.

`DVAIBridgeState`:

| Field          | Type            | When set |
|----------------|-----------------|----------|
| `isReady`      | `boolean`       | Always.  |
| `baseUrl`      | `string?`       | When `isReady`. |
| `port`         | `number?`       | When `isReady`. |
| `backend`      | `BackendKind?`  | When `isReady`. |
| `modelId`      | `string?`       | When `isReady`. |
| `lastProgress` | `ProgressEvent?`| Stashes the most-recent progress event. |

## Imperative progress listener

If you need progress events outside a component:

```ts
const sub = DVAIBridge.addProgressListener((event) => {
  switch (event.kind) {
    case "started":   console.log(`${event.phase} started`); break;
    case "progress":  console.log(`${event.phase} ${event.percent ?? "?"}%`); break;
    case "completed": console.log(`${event.phase} done`); break;
    case "failed":    console.error(`${event.phase} failed: ${event.error.message}`); break;
  }
});
// later:
sub.remove();
```

Every event has a `phase: "start" | "stop" | "download"` discriminator
plus a `kind` discriminator. The native modules emit identical JSON shapes
on both iOS and Android.

## Model download

```ts
const result = await DVAIBridge.downloadModel({
  url: "https://huggingface.co/example/model/resolve/main/model.gguf",
  sha256: "abc123…",
});
console.log(result.path, result.sizeBytes);
```

The download uses the platform-native downloader (`URLSession` on iOS,
OkHttp on Android) — both stream straight to disk with sha-256
verification. Failing checksums delete the partial file and throw
`DVAIBridgeError(kind: "checksumMismatch")`.

## Errors

Every public method that can fail throws a `DVAIBridgeError` (a TS class
with a stable `kind` discriminator):

| `kind`                  | When                                                                        |
|-------------------------|------------------------------------------------------------------------------|
| `alreadyStarted`        | `start()` called twice without `stop()`.                                    |
| `notStarted`            | A method that requires `start()` was called before it.                       |
| `configurationInvalid`  | Bad `StartOptions` (e.g. unsupported `modelPath` extension under `Auto`).    |
| `modelLoadFailed`       | Backend rejected the model file or tokenizer.                                |
| `backendUnavailable`    | Backend can't run on this platform / build (CocoaPods MLX, Android `coreml`). |
| `backendError`          | Generic backend failure (HTTP server bind, inference exception).             |
| `checksumMismatch`      | `downloadModel` SHA-256 didn't match.                                        |
| `downloadFailed`        | `downloadModel` networking failure.                                          |

Pattern-match in TS:

```ts
import { DVAIBridgeError } from "@dvai-bridge/react-native";

try {
  await DVAIBridge.start({ backend: BackendKind.Foundation });
} catch (err) {
  if (err instanceof DVAIBridgeError && err.kind === "backendUnavailable") {
    // Fall back to a different backend.
    await DVAIBridge.start({ backend: BackendKind.Llama, modelPath: "..." });
  } else {
    throw err;
  }
}
```

## Distributed inference (`offload`) — v3.0+

`@dvai-bridge/react-native` v3.0+ surfaces the v3.0 distributed-inference
configuration. Pass an `offload` block to `start()` to enable LAN /
internet peer discovery and request offload when local capability is
insufficient. See the [Distributed Inference guide](./distributed-inference.md)
for the full feature description.

```ts
import { DVAIBridge, BackendKind } from "@dvai-bridge/react-native";

const server = await DVAIBridge.start({
  backend: BackendKind.Auto,
  modelPath: "/path/to/model.gguf",
  offload: {
    enabled: true,
    discoverLAN: true,
    minLocalCapability: 10,
    rendezvousUrl: "wss://rendezvous.myapp.com", // optional, internet path
  },
});
```

The `onPairingRequest` callback from the JS-side `OffloadConfig` cannot
cross the TurboModule boundary, so React Native consumers receive
inbound pairing requests via an event listener and respond via
`respondToPairing(requestId, approved)`:

```ts
const sub = DVAIBridge.addListener("pairingRequest", async (req) => {
  const approved = await myUiConfirm(req.peerDeviceName);
  await DVAIBridge.respondToPairing(req.id, approved);
});

// Tear down on unmount:
sub.remove();
```

Without a registered listener, inbound pairing requests are denied
after the request's `expiresAt` deadline.

## Outgoing offload (v3.2)

When `offload: { enabled: true }` is set, the underlying native
SDK (iOS Swift / Android Kotlin) runs a pre-routing proxy in front
of the native backend. RN consumer code is unchanged — `fetch` /
your OpenAI client points at `server.baseUrl` exactly as before;
the proxy decides per-request whether to serve locally or forward
to a paired peer.

```ts
import { DVAIBridge } from "@dvai-bridge/react-native";

const a = await DVAIBridge.assessHardware(3.0, 10.0);
switch (a.mode) {
  case "ok":
  case "offload-only":
    await DVAIBridge.start(opts);
    break;
  case "too-weak":
    showCustomNotSupportedAlert(a.reason);
    break;
}
```

The SDK never shows UI for hardware decisions — your app does. See
the [distributed-inference guide](./distributed-inference.md#v32--per-sdk-outgoing-offload-routing)
for the full contract.

## Build / publish (for contributors)

The package builds with `react-native-builder-bob` (CommonJS + ESM +
TypeScript types):

```bash
pnpm -F @dvai-bridge/react-native build
pnpm -F @dvai-bridge/react-native test
```

Native bridges compile during the consumer's `pod install` / Gradle sync
— there's no native build step inside this package. CI verifies the JS
build + Jest test surface; a separate `xcodebuild` job verifies the iOS
bridge against a sample RN 0.77+ app, and a Gradle job does the same for
Android.

## Reference

- [iOS Native SDK](./ios-native-sdk.md) — the underlying Swift surface.
- [Android Native SDK](./android-native-sdk.md) — the underlying Kotlin surface.
- [Backends comparison](./backends.md) — when to pick which engine.
- [MLX Backend](./mlx-backend.md) — the iOS-only MLX path (SwiftPM-only).
