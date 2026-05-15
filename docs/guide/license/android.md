# License setup — Android

You added `co.deepvoiceai:dvai-bridge` to your Gradle build and want
to ship a release APK / AAB. Here's the licensing path.

## TL;DR

Drop `dvai-license.jwt` into your app's `src/main/assets/` folder. At
`DVAIBridge.start(...)` time, the SDK reads it from the APK assets,
verifies the ES256 signature offline, and unlocks production
behaviour. In `debug` build variants the SDK ignores license problems.

## Where the file goes

Add the license file as an Android asset:

```
app/
  src/
    main/
      assets/
        dvai-license.jwt
```

It ships inside the APK, accessible via `context.assets.open(...)`.

Alternative locations the SDK also checks (in priority order):

1. An inline JWT passed to `StartOptions(licenseToken = "...")` —
   useful when the token comes from your account flow at runtime.
2. A path passed to `StartOptions(licenseKeyPath = ...)` — e.g. a
   file your app downloaded into `Context.filesDir`.
3. `assets/dvai-license.jwt` (auto-discovered).

## Code: with vs. without

Default (license bundled in `assets/`):

```kotlin
import co.deepvoiceai.bridge.DVAIBridge
import co.deepvoiceai.bridge.StartOptions

val bound = DVAIBridge.start(StartOptions(
    backend = BackendKind.Llama,
    modelPath = modelFile.absolutePath
))
println(bound.baseUrl)              // http://127.0.0.1:38883/v1
println(bound.licenseStatus)        // LicenseStatus.Commercial(licensee = "Acme", ...)
```

With an inline JWT (downloaded at runtime, stored in EncryptedSharedPreferences):

```kotlin
val token = encryptedPrefs.getString("dvai_license_jwt", null)!!

val bound = DVAIBridge.start(StartOptions(
    backend = BackendKind.Llama,
    modelPath = modelFile.absolutePath,
    licenseToken = token
))
```

With an explicit file path:

```kotlin
val licensePath = File(context.filesDir, "dvai-license.jwt").absolutePath
val bound = DVAIBridge.start(StartOptions(
    backend = BackendKind.Llama,
    modelPath = modelFile.absolutePath,
    licenseKeyPath = licensePath
))
```

::: tip Native license fields land in v3.3
In v3.2.x, the Android SDK ships without `licenseToken` /
`licenseKeyPath` on `StartOptions`. The Capacitor-wrapped path runs
the JS validator automatically; pure-native Kotlin apps in v3.2 ship
under a "dev preview" allowance. Native Android validation arrives
in v3.3 — track
[the milestone](https://github.com/dvai-global/dvai-bridge) for the
release date and pin to v3.3+ to enforce on Android.
:::

## What happens without a license

In `release` build variants, `start(...)` throws
`DVAIBridgeError.LicenseRequired` with a verbose message:

```kotlin
try {
    val bound = DVAIBridge.start(...)
} catch (e: DVAIBridgeError.LicenseRequired) {
    // e.message is a multi-line string with resolution steps.
    Log.e("dvai", e.message ?: "")
    showSnackbar("License required: ${e.shortReason}")
}
```

## Testing locally without a license

`debug` build variants skip license checks automatically. The SDK
detects debug mode via `BuildConfig.DEBUG` and
`ApplicationInfo.FLAG_DEBUGGABLE`.

To force dev mode explicitly:

```kotlin
System.setProperty("DVAI_FORCE_DEV", "1")
```

To rehearse the release code path inside a debug build:

```kotlin
System.setProperty("DVAI_FORCE_PROD", "1")
```

## When validation fails

| Error reason fragment | What's wrong | Fix |
| --- | --- | --- |
| `asset not found` | `dvai-license.jwt` isn't in `src/main/assets/` | Drop it in, rebuild |
| `signature did not verify` | Token tampered with or wrong key | Re-download from your licensor |
| `does not authorise platform "android"` | License missing `"android"` in `platforms` claim | Re-issue covering Android |
| `audience entries ... do not match` | Package name doesn't match `aud` entries | Re-issue with your `applicationId`, or use a wildcard pattern |
| `expired` | Past `exp` | Renew |

The runtime audience on Android is your application's `packageName`
(e.g. `com.acme.app`). License templates typically include both your
package name and a `"*"` fallback for trials.

## See also

- [License setup index](./index)
- [Pre-init inspection](./pre-init-inspection) — run `LicenseValidator`
  standalone for a settings-screen license status without
  `DVAIBridge.start()`.
- [Android Native SDK](/guide/android-native-sdk) — full SDK reference.
- [Capacitor](./capacitor) — if you ship via Capacitor instead of
  native Kotlin.
