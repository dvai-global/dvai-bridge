# License setup — iOS

You added the `DVAIBridge` SwiftPM (or CocoaPods) dependency and want
to ship to the App Store. Here's the licensing path.

## TL;DR

Add `dvai-license.jwt` to your Xcode project's main bundle as a
resource. At app launch, the SDK reads it from the bundle, verifies
the ES256 signature offline, and unlocks production behaviour. In
Debug builds the SDK ignores license problems.

## Where the file goes

Add the license file as a bundled resource so it ships inside the
`.app` package:

1. Drop `dvai-license.jwt` into your Xcode project (drag-and-drop or
   File → Add Files…).
2. In the file inspector, tick **Target Membership** for your app
   target.
3. Make sure it appears under **Build Phases → Copy Bundle Resources**.

The runtime location is `Bundle.main.url(forResource: "dvai-license",
withExtension: "jwt")`. The SDK looks there first.

Alternative locations the SDK also checks (in priority order):

1. An inline JWT passed to `start(.init(licenseToken: "..."))` — useful
   when the token comes from your account flow at runtime.
2. A path passed to `start(.init(licenseKeyPath: ...))` — e.g. a file
   downloaded into `Application Support`.
3. `Bundle.main` → `dvai-license.jwt`.

## Code: with vs. without

Default (license bundled at `dvai-license.jwt`):

```swift
import DVAIBridge

let bound = try await DVAIBridge.shared.start(.init(
    backend: .llama,
    modelPath: modelURL.path
))
print(bound.baseUrl)             // http://127.0.0.1:38883/v1
print(bound.licenseStatus)       // .commercial(licensee: "Acme", ...)
```

With an inline JWT (downloaded at runtime, stored in Keychain):

```swift
let token = try keychain.read("dvai-license-jwt")

let bound = try await DVAIBridge.shared.start(.init(
    backend: .llama,
    modelPath: modelURL.path,
    licenseToken: token
))
```

With an explicit file path:

```swift
let bound = try await DVAIBridge.shared.start(.init(
    backend: .llama,
    modelPath: modelURL.path,
    licenseKeyPath: licensePath
))
```

::: tip Native license fields land in v3.3
In v3.2.x, the iOS SDK ships without `licenseToken` /
`licenseKeyPath` on `StartOptions`. The Capacitor-wrapped path runs
the JS validator automatically; pure-native Swift apps in v3.2 ship
under a "dev preview" allowance. Native iOS validation arrives in
v3.3 — track [the milestone](https://github.com/Westenets/dvai-bridge)
for the release date and pin to v3.3+ to enforce on iOS.
:::

## What happens without a license

In Release builds, `start(...)` throws `DVAIBridgeError.licenseRequired`
with a verbose user-facing message:

```swift
do {
    let bound = try await DVAIBridge.shared.start(...)
} catch DVAIBridgeError.licenseRequired(let reason) {
    // reason is a multi-line string suitable for a crash log.
    print(reason)
    showAlert(title: "License required", message: reason)
}
```

The reason includes which check failed (missing file, expired,
audience mismatch, etc.) and the resolution steps.

## Testing locally without a license

Debug builds skip license checks automatically. The SDK detects Debug
mode via the `DEBUG` compile flag and the simulator's environment.

To force dev mode explicitly (e.g. for a TestFlight build you want to
distribute without a real license):

```swift
ProcessInfo.processInfo.environment["DVAI_FORCE_DEV"] = "1"
```

To rehearse the production code path inside a Debug build:

```swift
setenv("DVAI_FORCE_PROD", "1", 1)
```

## When validation fails

| Error reason fragment | What's wrong | Fix |
| --- | --- | --- |
| `bundle resource not found` | `dvai-license.jwt` isn't in Copy Bundle Resources | Re-add to the target |
| `signature did not verify` | Token tampered with or wrong key | Re-download from your licensor |
| `does not authorise platform "ios"` | License missing `"ios"` in `platforms` claim | Re-issue covering iOS |
| `audience entries ... do not match` | Bundle id doesn't match `aud` entries | Re-issue with your `CFBundleIdentifier`, or use a wildcard pattern |
| `expired` | Past `exp` | Renew |

The runtime audience on iOS is `Bundle.main.bundleIdentifier`. License
templates typically include both your bundle id (e.g.
`com.acme.app`) and a `"*"` fallback for trials.

## See also

- [License setup index](./index)
- [iOS Native SDK](/guide/ios-native-sdk) — full SDK reference.
- [Capacitor](./capacitor) — if you ship via Capacitor instead of
  native Swift.
