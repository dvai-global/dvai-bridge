# Phase 3E — React Native Module (`@dvai-bridge/react-native`)

**Status:** Draft — awaiting review
**Date:** 2026-04-27
**Scope:** A React Native TurboModule that wraps the Phase 3C iOS Native SDK + Phase 3D Android Native SDK behind a shared TS API. Drop-in for any RN ≥ 0.74 app (Bridgeless on by default); zero JS-bundle inference engine, zero JSI native invocations beyond the boot path.

**Sub-phase position in Phase 3:**

```
3A core extraction ✅ → 3B LiteRT-LM migration ✅ → 3C iOS SDK ✅
                                                  → 3D Android AAR ✅
                                                  → 3E React Native ◀️ YOU ARE HERE
                                                  → 3F Flutter
                                                  → 3G .NET NuGet
                                                  → 3H docs / publish / launch
```

3E is thin: both native SDKs already speak the same `DVAIBridge` shape (8-method singleton + reactive state). 3E is a TurboModule that translates JS calls into native calls and surfaces the OpenAI-compatible HTTP server's `baseUrl` so consumers point any OpenAI-compatible RN client at `http://127.0.0.1:<port>/v1`.

---

## 1. Goals

1. Stand up `packages/dvai-bridge-react-native/` — npm package `@dvai-bridge/react-native`. Single TurboModule (`NativeDVAIBridge`) that surfaces the 8-method DVAIBridge API to JS / TS.
2. Public TS API mirrors the iOS / Android shape:
   ```ts
   import { DVAIBridge, BackendKind } from "@dvai-bridge/react-native";

   const server = await DVAIBridge.start({
     backend: BackendKind.Auto,
     modelPath: "/path/to/model.gguf",
   });
   console.log(server.baseUrl); // "http://127.0.0.1:38883/v1"
   await DVAIBridge.stop();
   ```
3. Two thin bridging targets:
   - **iOS bridge**: Swift module that depends on `DVAIBridge` (the SwiftPM/CocoaPods target from Phase 3C v2.1) and translates RN calls into `DVAIBridge.shared.start(...)` / etc.
   - **Android bridge**: Kotlin module that depends on `co.deepvoiceai:dvai-bridge:2.1.0` (Phase 3D umbrella AAR) and translates RN calls into `DVAIBridge.start(...)`.
4. Cross-platform `BackendKind` is the **union** of iOS and Android cases:
   ```ts
   enum BackendKind {
     Auto = "auto",
     Llama = "llama",
     Foundation = "foundation",  // iOS-only
     CoreML = "coreml",           // iOS-only
     MLX = "mlx",                 // iOS-only
     MediaPipe = "mediapipe",     // Android-only
     LiteRT = "litert",           // Android-only
   }
   ```
   Native modules throw `DVAIBridgeError.backendUnavailable` when the requested backend doesn't exist on the platform.
5. Reactive state surface: `useDVAIBridgeState()` React hook backed by `NativeEventEmitter` over the iOS `Combine` / Android `Flow` events. Polling-free.
6. Build pipeline: TypeScript source → CommonJS + ESM dist via `react-native-builder-bob`. Type definitions emitted alongside.

## 2. Non-goals (3E)

- **WebRTC / streaming** — RN is a chat-completion client today. Streaming responses (SSE) come through the existing `/v1/chat/completions` HTTP path; RN doesn't add a new transport.
- **Zero-rebuild model swap** — same as the underlying SDKs: `start()` / `stop()` cycles around model changes.
- **Expo plugin** — bare RN only in 3E. Expo support (a config plugin auto-injecting the native deps) is a follow-up.
- **Flutter / .NET** — those are 3F / 3G. 3E is RN-only.
- **Old-arch bridge** — RN ≥ 0.74 has Bridgeless ON by default; we ship a TurboModule, not a legacy `RCTBridgeModule`. RN ≤ 0.73 consumers stay on dvai-bridge-capacitor (or pin to a legacy `@dvai-bridge/react-native@1.x` that we won't ship for 3E).
- **Sample app** — out of scope (per the project's "scripted samples" convention). Docs include a copy-paste-ready snippet; users wire it into their own app.

## 3. Architecture

### 3.1 Package layout

```
packages/dvai-bridge-react-native/
├── package.json                            # @dvai-bridge/react-native, peerDep on react-native
├── README.md                               # synced via scripts/sync-package-meta.js
├── tsconfig.json
├── tsconfig.build.json
├── babel.config.js
├── react-native.config.js                  # autolinking config
├── src/
│   ├── index.ts                            # public re-exports
│   ├── DVAIBridge.ts                       # TS facade calling NativeDVAIBridge
│   ├── NativeDVAIBridge.ts                 # TurboModule codegen spec
│   ├── types.ts                            # BackendKind, StartOptions, BoundServer, etc.
│   ├── errors.ts                           # DVAIBridgeError union type
│   └── hooks/
│       └── useDVAIBridgeState.ts           # NativeEventEmitter-backed React hook
├── ios/
│   ├── DVAIBridgeNative.podspec            # depends on DVAIBridge umbrella from Phase 3C
│   ├── DVAIBridgeNative.swift              # TurboModule impl, calls DVAIBridge.shared
│   └── DVAIBridgeNative.mm                 # Obj-C++ TurboModule registration
├── android/
│   ├── build.gradle                        # depends on co.deepvoiceai:dvai-bridge:2.1.0
│   ├── src/main/java/co/deepvoiceai/bridge/rn/
│   │   ├── DVAIBridgeNativeModule.kt       # TurboModule impl, calls DVAIBridge
│   │   └── DVAIBridgePackage.kt            # registers the module
│   └── src/main/AndroidManifest.xml
└── example/                                # scripted, not implemented (per project convention)
    └── README.md                           # quickstart pointing at the consumer guide
```

### 3.2 Public API surface (TS)

```ts
import { DVAIBridge, BackendKind } from "@dvai-bridge/react-native";

const server = await DVAIBridge.start({
  backend: BackendKind.Auto,
  modelPath: "/path/to/model.gguf",
  contextSize: 2048,
  threads: 4,
});

console.log(server.baseUrl);    // http://127.0.0.1:38883/v1
console.log(server.port);       // 38883
console.log(server.backend);    // BackendKind
console.log(server.modelId);

const status = await DVAIBridge.status();
await DVAIBridge.stop();

// Reactive state — React hook backed by NativeEventEmitter.
const state = useDVAIBridgeState();
console.log(state.isReady, state.baseUrl, state.backend);

// Progress events — JS-side EventEmitter API.
const sub = DVAIBridge.addProgressListener(event => console.log(event));
sub.remove();
```

### 3.3 TurboModule spec

```ts
// src/NativeDVAIBridge.ts
import type { TurboModule } from "react-native";
import { TurboModuleRegistry } from "react-native";

export interface Spec extends TurboModule {
  startBridge(opts: object): Promise<object>;
  stopBridge(): Promise<void>;
  status(): Promise<object>;
  downloadModel(opts: object): Promise<object>;
  // Progress events emitted via NativeEventEmitter on the "DVAIBridgeProgress" name.
  addListener(eventName: string): void;
  removeListeners(count: number): void;
}

export default TurboModuleRegistry.getEnforcing<Spec>("DVAIBridge");
```

`object` is used for the loose opts/result types because RN codegen doesn't support union types for nullable fields well as of RN 0.77. The TS facade in `src/DVAIBridge.ts` validates and coerces between `object` and the strongly-typed `StartOptions` / `BoundServer`.

### 3.4 Cross-platform validation

Because `BackendKind` is the union of iOS and Android cases, the TS facade does first-pass validation:

```ts
import { Platform } from "react-native";

const IOS_ONLY: BackendKind[] = [BackendKind.Foundation, BackendKind.CoreML, BackendKind.MLX];
const ANDROID_ONLY: BackendKind[] = [BackendKind.MediaPipe, BackendKind.LiteRT];

export async function start(opts: StartOptions): Promise<BoundServer> {
  if (Platform.OS === "ios" && ANDROID_ONLY.includes(opts.backend)) {
    throw new DVAIBridgeError("backendUnavailable",
      `${opts.backend} is Android-only`);
  }
  if (Platform.OS === "android" && IOS_ONLY.includes(opts.backend)) {
    throw new DVAIBridgeError("backendUnavailable",
      `${opts.backend} is iOS-only`);
  }
  return NativeDVAIBridge.startBridge(opts);
}
```

The native modules are still authoritative — they throw a matching `backendUnavailable` if the consumer somehow bypasses the TS check.

### 3.5 Reactive state via NativeEventEmitter

Both native sides emit `ProgressEvent`s. The Swift bridge wraps `DVAIBridge.shared.progressPublisher` as a `RCTEventEmitter` event, the Kotlin bridge does the same with `DVAIBridge.progressFlow`. The TS hook subscribes via `NativeEventEmitter` and exposes a typed React state value:

```ts
export function useDVAIBridgeState(): DVAIBridgeState {
  const [state, setState] = useState<DVAIBridgeState>({ isReady: false });
  useEffect(() => {
    DVAIBridge.status().then(s => setState(s));
    const sub = DVAIBridge.addProgressListener(event => {
      if (event.kind === "completed" && event.phase === "start") {
        DVAIBridge.status().then(setState);
      } else if (event.kind === "completed" && event.phase === "stop") {
        setState({ isReady: false });
      }
    });
    return () => sub.remove();
  }, []);
  return state;
}
```

## 4. Distribution

### 4.1 npm — GitHub Packages

Same convention as the rest of the dvai-bridge family:

- `package.json` declares `publishConfig.registry = https://npm.pkg.github.com`
- Consumers add `@dvai-bridge:registry=https://npm.pkg.github.com` to their `.npmrc`
- Token in `~/.npmrc` with `read:packages` scope

### 4.2 Native autolinking

`react-native.config.js` declares the iOS pod + Android Gradle module so RN's autolinking picks them up:

```js
module.exports = {
  dependency: {
    platforms: {
      ios: {
        podspecPath: __dirname + "/ios/DVAIBridgeNative.podspec",
      },
      android: {
        sourceDir: __dirname + "/android",
      },
    },
  },
};
```

### 4.3 Consumer integration

```bash
npm install @dvai-bridge/react-native --registry=https://npm.pkg.github.com
cd ios && pod install
```

Then:

```ts
import { DVAIBridge, BackendKind, useDVAIBridgeState } from "@dvai-bridge/react-native";
```

## 5. Versioning

3E ships under the `2.x.y` line. Phase 3D was tagged at `v2.1.0`; Phase 3E is `v2.2.0` (minor bump — additive). Once 3F (Flutter) and 3G (.NET) follow, they bump 2.3.0 and 2.4.0 respectively.

## 6. Open questions

1. **`react-native-builder-bob` version**: 0.40.x is the latest stable as of 2026-04-27. Verify against Maven Central / npm at task start to use the latest.
2. **iOS pod dep on `DVAIBridge`**: do we depend on the SwiftPM-only `DVAIBridge` umbrella (no CocoaPods support for the MLX backend), or on the CocoaPods `DVAIBridge.podspec`? Decision: depend on the CocoaPods podspec for `pod install` consumer compat; document that MLX backend is unavailable under CocoaPods (same caveat that already applies to Capacitor). RN consumers who want MLX can opt into SPM via `:path` in their `Podfile` or wait for an Expo plugin to land in 3H.
3. **Bridgeless / TurboModule version pinning**: minimum RN we support. Decision: RN 0.74+ (Bridgeless ON by default). Older RN consumers stay on Capacitor.
4. **Codegen output committed or generated at install time**: RN's TurboModule codegen runs at `pod install` / Gradle sync time. Output is gitignored. Confirm this matches RN 0.74+ behavior.

## 7. References

- Phase 3C iOS SDK spec: [docs/superpowers/specs/2026-04-26-phase3c-ios-native-sdk-design.md](2026-04-26-phase3c-ios-native-sdk-design.md)
- Phase 3D Android SDK spec: [docs/superpowers/specs/2026-04-27-phase3d-android-native-sdk-design.md](2026-04-27-phase3d-android-native-sdk-design.md)
- Phase 3 foundation spec: [docs/superpowers/specs/2026-04-26-phase3-foundation-design.md](2026-04-26-phase3-foundation-design.md)
- React Native TurboModules guide: https://reactnative.dev/docs/the-new-architecture/pure-cxx-modules (or Bridgeless mode docs at https://reactnative.dev/blog/2024/10/23/the-new-architecture-is-here)
- Existing iOS DVAIBridge SDK: `packages/dvai-bridge-ios/`
- Existing Android DVAIBridge SDK: `packages/dvai-bridge-android/`
