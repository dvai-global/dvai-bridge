# Pre-init license inspection

You can run the license validator independently of the SDK's main
startup sequence. This is useful when:

- A dashboard / settings UI wants to display the licensee, expiry, or
  tier without paying the full cost of `DVAI.initialize()` /
  `DVAIBridge.start()` (which loads models, starts the embedded HTTP
  server, performs backend init).
- A setup wizard wants to verify the license file before committing
  the user to a model download.
- A CI smoke wants to confirm that a license artifact is valid before
  running the full integration test.

The same `LicenseValidator` class that the SDK uses internally during
`initialize()` is exposed on every SDK's public surface. Same JWT
format, same claim checks, same dev-mode bypass rules everywhere.

## TypeScript / Node / Browser / Capacitor JS layer

`@dvai-bridge/core`:

```ts
import { LicenseValidator, type LicenseStatus } from "@dvai-bridge/core";

const status: LicenseStatus = await new LicenseValidator().validate();

// status.kind ∈ "commercial" | "trial" | "free-dev" | "free-prod" | "free-expired"
switch (status.kind) {
  case "commercial":
  case "trial":
    console.log(`Licensed to ${status.licensee} until ${new Date(status.expiresAt * 1000).toISOString()}`);
    break;
  case "free-dev":
    console.log("Running in dev mode — no license required");
    break;
  case "free-prod":
    console.warn(`License needed before SDK can start: ${status.reason}`);
    break;
  case "free-expired":
    console.warn(`License expired for ${status.licensee}`);
    break;
}
```

`validate()` never throws. Use `validateAndAssert()` instead if you
want the same throw-on-prod behavior the SDK itself uses at startup.

## Swift (iOS / macOS / Mac Catalyst)

`DVAIBridge`:

```swift
import DVAIBridge

let validator = LicenseValidator()
let status = await validator.validate()

switch status {
case .commercial(let licensee, let expiresAt, _, _):
    print("Licensed to \(licensee), expires \(Date(timeIntervalSince1970: TimeInterval(expiresAt)))")
case .trial(let licensee, let expiresAt, _, _):
    print("Trial license for \(licensee) until \(Date(timeIntervalSince1970: TimeInterval(expiresAt)))")
case .freeDev(let reason):
    print("Dev mode: \(reason)")
case .freeProd(let reason):
    print("License required: \(reason)")
case .freeExpired(let licensee, let expiredAt):
    print("Expired license for \(licensee) at \(Date(timeIntervalSince1970: TimeInterval(expiredAt)))")
}
```

For the throw variant: `try await validator.validateAndAssert()`.

## Kotlin (Android)

`co.deepvoiceai.bridge.license.LicenseValidator`:

```kotlin
import android.content.Context
import co.deepvoiceai.bridge.license.LicenseStatus
import co.deepvoiceai.bridge.license.LicenseValidator

// In a Coroutine scope or suspend function:
suspend fun checkLicense(context: Context, isDebugBuild: Boolean) {
    val validator = LicenseValidator(
        context = context.applicationContext,
        hostBuildConfigDebug = isDebugBuild,  // pass your app's BuildConfig.DEBUG
    )
    when (val status = validator.validate()) {
        is LicenseStatus.Commercial ->
            Log.i("DVAI", "Licensed to ${status.licensee} until ${status.expiresAt}")
        is LicenseStatus.Trial ->
            Log.i("DVAI", "Trial license for ${status.licensee}")
        is LicenseStatus.FreeDev ->
            Log.d("DVAI", "Dev mode: ${status.reason}")
        is LicenseStatus.FreeProd ->
            Log.w("DVAI", "License required: ${status.reason}")
        is LicenseStatus.FreeExpired ->
            Log.w("DVAI", "Expired license for ${status.licensee}")
    }
}
```

The Kotlin validator needs the `Context` to read `packageName` (for
audience binding) and to discover assets / raw resources. Pass your
host app's `BuildConfig.DEBUG` so the dev-mode bypass picks up the
right value (the library module's own `BuildConfig.DEBUG` doesn't
reflect your app's build variant).

## C# / .NET (MAUI, Avalonia, WinUI, Desktop)

`DVAIBridge.License`:

```csharp
using DVAIBridge.License;

var validator = new LicenseValidator();
var status = await validator.ValidateAsync();

switch (status)
{
    case LicenseStatus.Commercial c:
        Console.WriteLine($"Licensed to {c.Licensee} until {DateTimeOffset.FromUnixTimeSeconds(c.ExpiresAt)}");
        break;
    case LicenseStatus.Trial t:
        Console.WriteLine($"Trial license for {t.Licensee}");
        break;
    case LicenseStatus.FreeDev d:
        Console.WriteLine($"Dev mode: {d.Reason}");
        break;
    case LicenseStatus.FreeProd p:
        Console.WriteLine($"License required: {p.Reason}");
        break;
    case LicenseStatus.FreeExpired e:
        Console.WriteLine($"Expired license for {e.Licensee}");
        break;
}
```

For the throw variant: `await validator.ValidateAndAssertAsync()`
which throws `LicenseRequiredException`.

## Dart (Flutter)

`package:dvai_bridge/dvai_bridge.dart`:

```dart
import 'package:dvai_bridge/dvai_bridge.dart';

final validator = LicenseValidator();
final status = await validator.validate();

// status is a sealed class — switch on the runtime type:
switch (status) {
  case Commercial(:final licensee, :final expiresAt):
    print('Licensed to $licensee until ${DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000)}');
  case Trial(:final licensee):
    print('Trial license for $licensee');
  case FreeDev(:final reason):
    print('Dev mode: $reason');
  case FreeProd(:final reason):
    print('License required: $reason');
  case FreeExpired(:final licensee):
    print('Expired license for $licensee');
}
```

For the throw variant: `await validator.validateAndAssert()` which
throws `LicenseRequiredException`.

## React Native + Capacitor

These wrappers don't ship a JS-side LicenseValidator of their own —
the license check happens on the native side (Swift / Kotlin) at
startup. If you want pre-init validation from the JS layer:

- **Capacitor**: install `@dvai-bridge/core` as a regular dependency
  alongside `@dvai-bridge/capacitor` and use the TypeScript example
  above. The core's validator reads the same `dvai-license.jwt` your
  app already ships (it's a same-origin fetch from `public/`).
- **React Native**: same — install `@dvai-bridge/core` and use the
  TypeScript example. Note that audience binding from a Node-style
  context won't have `window.location.hostname`; either pass
  `DVAI_AUDIENCE` via `process.env` shim or pre-read your bundle id
  via the native module and pass it through `audienceOverride`.

## Same JWT file works everywhere

All five SDK validators read the same `dvai-license.jwt` format and
verify with the same `kid`-keyed public-key registry. One license
issued by `dvai-license-generator` with platforms `["ios", "android",
"web", "dotnet", "flutter", "react-native", "capacitor", "node"]`
activates across every SDK that consumes it.

## See also

- [License setup overview](./) — per-platform file-drop walkthrough
- [Migration v3.x → v4.0](../../migration/v3-to-v4) — the throw-on-prod
  policy + field rename context
