# License setup — React Native

You added `@dvai-bridge/react-native` to a React Native (≥ 0.77,
Bridgeless ON) app and want to ship a release. Here's the licensing
path.

## TL;DR

Drop `dvai-license.jwt` into your app's project root and reference it
in your platform bundle configs (iOS `Resources`, Android `assets/`).
At `DVAIBridge.start(...)` time, the SDK reads it from the bundle on
the native side, verifies the ES256 signature offline, and unlocks
production behaviour. In development builds (Metro dev server) the SDK
ignores license problems.

## Where the file goes

You need the file available to the **native** side, since the
TurboModule reads it from the platform bundle:

**iOS** — add to `ios/<YourApp>/`:

```
ios/MyApp/dvai-license.jwt
```

Then in Xcode, add the file to the app target and confirm it appears
in **Copy Bundle Resources** (see the [iOS page](./ios) for the
file-inspector steps).

**Android** — add to `android/app/src/main/assets/`:

```
android/app/src/main/assets/dvai-license.jwt
```

Alternative locations the SDK also checks:

1. Inline JWT via `start({ licenseToken: "..." })`.
2. Explicit path via `start({ licenseKeyPath: "..." })`.
3. Platform-default bundle resource (auto-discovered).

## Code: with vs. without

Default (license bundled on both platforms):

```ts
import { DVAIBridge } from "@dvai-bridge/react-native";

const bound = await DVAIBridge.start({
  backend: "llama",
  modelPath: modelPath,
});

console.log(bound.baseUrl);           // http://127.0.0.1:38883/v1
console.log(bound.licenseStatus);     // { kind: "commercial", ... }
```

Inline JWT (e.g. fetched from your account API):

```ts
const token = await api.getDvaiLicense();

const bound = await DVAIBridge.start({
  backend: "llama",
  modelPath,
  licenseToken: token,
});
```

Explicit path (e.g. a file saved into RNFS document directory):

```ts
import RNFS from "react-native-fs";

const bound = await DVAIBridge.start({
  backend: "llama",
  modelPath,
  licenseKeyPath: `${RNFS.DocumentDirectoryPath}/dvai-license.jwt`,
});
```

::: tip Native license fields land in v3.3
In v3.2.x, the React Native SDK ships without `licenseToken` /
`licenseKeyPath` on `start()`. Pure React Native apps in v3.2 ship
under a "dev preview" allowance. Native React Native validation
arrives in v3.3 — pin to v3.3+ to enforce on React Native.
:::

## What happens without a license

In release builds (`./gradlew assembleRelease`, `xcodebuild archive`),
`start(...)` rejects with a `LicenseRequiredError`-shaped object:

```ts
try {
  await DVAIBridge.start(...);
} catch (err: any) {
  if (err.code === "LICENSE_REQUIRED") {
    // err.message is a multi-line string with resolution steps.
    // err.status is "free-prod" | "free-expired".
    Alert.alert("License required", err.message);
  }
}
```

## Testing locally without a license

Metro / dev-server builds (`__DEV__ === true`) automatically enable
dev mode. The native module checks `BuildConfig.DEBUG` on Android and
the `DEBUG` macro on iOS.

To force dev mode explicitly in a release build:

```ts
DVAIBridge.setEnv({ DVAI_FORCE_DEV: "1" });
```

To rehearse the production code path in a debug build:

```ts
DVAIBridge.setEnv({ DVAI_FORCE_PROD: "1" });
```

## When validation fails

The platform-specific failures mirror [iOS](./ios) and
[Android](./android). The `aud` audience claim must match the iOS
bundle id OR the Android `applicationId` (whichever is running) — most
licenses include both, plus a `"*"` fallback.

## See also

- [License setup index](./index)
- [Pre-init inspection](./pre-init-inspection) — pull
  `@dvai-bridge/core` as a separate dep for JS-side license
  inspection in an RN settings screen without `DVAIBridge.start()`.
- [React Native SDK](/guide/react-native-sdk) — full SDK reference.
- [iOS](./ios) and [Android](./android) — platform-specific
  details that bubble up to the React Native module.
