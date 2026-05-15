# Migration: v3.x → v4.0

**TL;DR — three changes you need to know about:**

1. The `licenseKey: string` config field is **gone**. Replace it with
   either `licenseKeyPath` (file path) or `licenseToken` (inline JWT).
2. Production deployments without a valid license now **throw**
   `LicenseRequiredError` at SDK startup. The previous "free-prod tier
   with attribution badge" path is removed.
3. Development environments (localhost, debug builds, `NODE_ENV=test`,
   `DVAI_FORCE_DEV=1`) bypass licensing entirely — devs running
   locally need no changes.

If your apps only run in dev mode (CI / localhost / debug builds), no
code changes are required. If you ship to production, follow the
walkthrough below.

[License setup, per platform →](/guide/license/)

---

## Why this release is v4.0.0 (major)

Two breaking changes drive the major bump:

- **API surface change**: a public field on `DVAIConfig` / `StartOptions`
  was removed.
- **Behaviour change**: the SDK refuses to start in production without
  a valid license, where v3 would warn and continue.

Everything else is additive. The OpenAI HTTP wire contract, the
backend matrix, the distributed-inference plane, the SDK lifecycle —
all unchanged. v3 agent code keeps working against v4 SDKs as long as
the license file is in place.

---

## What changed

### Removed

- **`DVAIConfig.licenseKey: string`** (and equivalent fields on every
  native SDK's `StartOptions`). The plaintext-key checksum design it
  fed was retired. Setting this field on v4 has no effect — TypeScript
  will reject it at compile time; native compilers will reject the
  field name.

### Added — license configuration

Every SDK gains two new optional fields:

- **`licenseKeyPath?: string`** — explicit path (or URL, in browser
  contexts) to a `dvai-license.jwt` file. The SDK reads + verifies it
  at startup.
- **`licenseToken?: string`** — inline JWT string. Useful in CI /
  serverless / env-var-driven deploys where a file isn't practical.
  Wins over `licenseKeyPath` if both are set.

If neither is configured, the SDK auto-discovers from
platform-conventional locations:

| Platform | Default discovery path |
|---|---|
| Node | `process.cwd()/dvai-license.jwt`, then one level up |
| Browser / Capacitor | same-origin `/dvai-license.jwt` |
| iOS | `Bundle.main.url(forResource: "dvai-license", withExtension: "jwt")` → `Application Support/dvai-bridge/dvai-license.jwt` → Documents → App Group container |
| Android | `assets/dvai-license.jwt` → `res/raw/dvai_license` → `filesDir/dvai-license.jwt` |
| .NET | `AppContext.BaseDirectory/dvai-license.jwt` → `%LOCALAPPDATA%/dvai-bridge/dvai-license.jwt` |
| Flutter | `assets/dvai-license.jwt` (via `rootBundle`) → Documents directory |

Two env vars work everywhere: `DVAI_LICENSE_PATH` (path) and
`DVAI_LICENSE_TOKEN` (inline JWT).

### Added — license status surface

- **`DVAI.licenseStatus` (TypeScript) / `BoundServer.licenseStatus`
  (native)** — discriminated value the host app can inspect after
  startup. `"commercial" | "trial" | "free-dev"` when the SDK is
  running. Host-app dashboards can display the licensee name, expiry,
  audience binding etc. without re-parsing the JWT.

### Added — `LicenseRequiredError`

Thrown from `DVAI.initialize()` / `DVAIBridge.start()` when the SDK
detects production / release mode AND there's no valid license. The
error's `localizedDescription` / `message` field includes:

- Why validation failed (missing file, expired, audience mismatch, etc.)
- Where to drop the license file
- How to bypass in dev (localhost, `NODE_ENV=test`, `DVAI_FORCE_DEV=1`,
  debug builds)

Catch it if you want a custom error UI; let it propagate if you want
the default behaviour ("app fails to start cleanly with an actionable
console message").

### Added — `LicenseValidator` on every SDK's public surface

Host apps that want to inspect license status *without* paying the
full cost of `DVAI.initialize()` / `DVAIBridge.start()` (which loads
models, starts the embedded HTTP server, runs the backend init) can
now run the validator standalone. Same API shape across every SDK:

```ts
// TypeScript / Node / browser / Capacitor JS layer
import { LicenseValidator } from "@dvai-bridge/core";
const status = await new LicenseValidator().validate();
```

```swift
// iOS / macOS / Mac Catalyst
import DVAIBridge
let status = await LicenseValidator().validate()
```

```kotlin
// Android (Context needed for packageName + asset discovery)
import co.deepvoiceai.bridge.license.LicenseValidator
val status = LicenseValidator(context, hostBuildConfigDebug = BuildConfig.DEBUG).validate()
```

```csharp
// .NET MAUI / Avalonia / WinUI / Desktop
using DVAIBridge.License;
var status = await new LicenseValidator().ValidateAsync();
```

```dart
// Flutter
import 'package:dvai_bridge/dvai_bridge.dart';
final status = await LicenseValidator().validate();
```

Useful for license-status pills in app chrome, settings pages,
setup wizards, CI smoke scripts, and any other place a full SDK
boot would be heavyweight. Full per-SDK walkthrough at
[pre-init license inspection](/guide/license/pre-init-inspection).

React Native and Capacitor consumers who want this from the JS layer
should install `@dvai-bridge/core` as a regular dependency alongside
the wrapper package; the wrappers themselves defer license validation
to the native iOS / Android validators at start time.

### Changed — dev mode auto-bypass

Unchanged in spirit but now load-bearing for the policy. The SDK runs
without a license when any of these are true:

- Browser hostname is `localhost`, `127.0.0.1`, `::1`, `*.local`,
  `192.168.*`, `10.*`, `172.*`
- `NODE_ENV === "test"` or `NODE_ENV === "development"`
- `DVAI_FORCE_DEV=1` env var set
- Capacitor's `Capacitor.DEBUG === true`
- iOS / .NET `#if DEBUG` build configuration
- Android `BuildConfig.DEBUG === true` or `FLAG_DEBUGGABLE` set on the
  app
- Flutter `kDebugMode` or `kProfileMode`
- iOS Simulator (`#if targetEnvironment(simulator)`)

`DVAI_FORCE_PROD=1` overrides every dev-mode signal — useful for
testing the production path locally before shipping.

---

## How to migrate

### Step 1 — obtain a license

If you have a commercial license already, skip to Step 2.

To obtain one, contact <https://deepvoiceai.com/dvai-bridge/license>.
Trial licenses are available for evaluation; commercial licenses are
required for production deployments.

You'll receive a `dvai-license.jwt` file. Treat it like any other
secret artifact (commit if you want it in version control, OR keep it
out of git and inject via env var — both work).

### Step 2 — drop the file at the default location

#### TypeScript / Node

```bash
# Drop at the project root
cp ~/Downloads/dvai-license.jwt ./dvai-license.jwt
```

Or set the env var:

```bash
export DVAI_LICENSE_PATH=/path/to/dvai-license.jwt
```

No code change needed if you use the default path.

#### Browser

Place `dvai-license.jwt` in your `public/` directory (Vite/Webpack/
etc.). It'll be served at the site root and auto-discovered.

```
your-app/
├── public/
│   └── dvai-license.jwt    ← place here
├── src/
└── package.json
```

#### iOS

Add the file as a bundle resource in Xcode (drag into the project
navigator with "Copy items if needed" + "Add to target").

Or programmatically:

```swift
let server = try await DVAIBridge.shared.start(StartOptions(
    backend: .llama,
    modelPath: "...",
    licenseKeyPath: Bundle.main.url(forResource: "dvai-license", withExtension: "jwt")?.path
))
```

#### Android

Place under `app/src/main/assets/dvai-license.jwt` (or
`app/src/main/res/raw/dvai_license`).

The SDK reads from assets automatically when `StartOptions.licenseKeyPath`
and `licenseToken` are both null.

#### .NET

Place `dvai-license.jwt` alongside your executable. For MAUI / WPF,
add it as a content file in the `.csproj`:

```xml
<ItemGroup>
  <Content Include="dvai-license.jwt">
    <CopyToOutputDirectory>PreserveNewest</CopyToOutputDirectory>
  </Content>
</ItemGroup>
```

#### Flutter

Add to your app's `pubspec.yaml`:

```yaml
flutter:
  assets:
    - assets/dvai-license.jwt
```

Place the file at `assets/dvai-license.jwt`.

#### React Native

Pass through as `licenseToken` from your env-loading layer (the JS
side can't read native assets cleanly, so an inline token is the
pragmatic path):

```ts
import { DVAIBridge } from "@dvai-bridge/react-native";
import licenseToken from "./dvai-license.jwt?raw"; // or read via fs

const state = await DVAIBridge.start({
  backend: BackendKind.Auto,
  modelPath: "...",
  licenseToken,
});
```

#### Capacitor

Place `dvai-license.jwt` in your `www/` (or `public/`) directory. The
JS-side validator fetches `/dvai-license.jwt` from the bundled web
content at startup.

### Step 3 — rename `licenseKey` if you set it

If your v3 code used `licenseKey: "dvai-..."`, remove that field. The
new fields replace it:

```ts
// v3:
const dvai = new DVAI({
  backend: "transformers",
  licenseKey: "dvai-...",  // ← REMOVE
});

// v4:
const dvai = new DVAI({
  backend: "transformers",
  // Either:
  licenseKeyPath: "./dvai-license.jwt",
  // OR:
  licenseToken: "eyJhbGciOiJFUzI1NiI...",
  // OR (recommended): set nothing and let auto-discovery find it
});
```

Same shape on every SDK — see the per-platform pages under
[License setup](/guide/license/).

### Step 4 — handle `LicenseRequiredError` if you want a custom UI

The default behaviour (uncaught throw → app fails to start with a
console error) is sensible for most deployments. If you want custom
error UI:

```ts
import { LicenseRequiredError } from "@dvai-bridge/core";

try {
  await dvai.initialize();
} catch (err) {
  if (err instanceof LicenseRequiredError) {
    // err.status: { kind: "free-prod" | "free-expired", ... }
    // err.message: developer-facing multi-line explanation
    showLicenseExpiredScreen(err.status);
  } else {
    throw err;
  }
}
```

Native SDKs expose the equivalent error type via their language's
conventions (`LicenseRequiredError` on Swift / Kotlin / Dart,
`LicenseRequiredException` on .NET).

---

## What didn't change

The OpenAI HTTP wire surface, the backend matrix, the distributed-
inference plane, the multi-tenant Hub, the per-SDK lifecycle, and
every other v3.x API are unchanged. Your agent code, your model
configurations, your peer-pairing flows — all keep working unaltered
after the license field is set up.

The dev-mode auto-bypass intent is unchanged too: developers running
locally on `pnpm dev` / `flutter run` / Xcode debug builds / Android
debug builds never need a license. Only release/production builds
enforce.

---

## Frequently anticipated questions

**Q: Can I keep the SDK working in production WITHOUT a license, like
v3 did?**

No, that's the whole point of v4. The v3 free-prod tier was a
permissive default; v4 makes commercial use require a commercial
license, consistent with the BSL 1.1 terms. If you want the v3
behaviour for evaluation, use a **trial license** (free, limited
duration, available from the same URL as commercial).

**Q: Does this break my CI builds?**

Only if your CI runs the SDK without setting `NODE_ENV=test` or
`DVAI_FORCE_DEV=1`. Both bypass licensing. Most CI configurations
already set `NODE_ENV=test` by default. If yours doesn't, add:

```yaml
env:
  DVAI_FORCE_DEV: "1"
```

**Q: How does the SDK validate licenses offline?**

Each SDK ships a public ECDSA P-256 key embedded in the binary. The
license is a signed JWT (ES256). The SDK verifies the signature
against the public key, checks audience binding (your domain / bundle
id) against the JWT's `aud` claim, and confirms `exp` is in the
future. No network calls. No phone-home.

**Q: What if my license expires?**

`LicenseRequiredError` with `status.kind === "free-expired"`. The
error message names the licensee and the expiry timestamp. Renew via
the same URL.

**Q: Can I have multiple environments / staging / production all
under one license?**

Yes — the license's `aud` array supports wildcards. A license bound to
`*.acme.com` matches `acme.com`, `app.acme.com`, `staging.acme.com`,
etc. Per-platform: native licenses bind to bundle id; one license can
list multiple bundle ids (`["com.acme.app", "com.acme.staging"]`).

**Q: How do I rotate keys?**

The SDK's public-key registry is `kid`-keyed (key id). Adding a new
key for rotation is just adding a new entry to the registry; old
licenses keep verifying against the old key until they expire, new
licenses verify against the new key. See
[the license-setup overview](/guide/license/) for the operator-side
rotation procedure.

---

## See also

- [License setup overview](/guide/license/) — per-platform walkthrough
- [LicenseValidator API](/reference/api#licensevalidator) — the public
  validator surface for host-app dashboards
- [Changelog v4.0.0](../../CHANGELOG) — full release notes
