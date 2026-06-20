# License setup

DVAI-Bridge is licensed under BSL 1.1. Production builds need a signed
license JWT. Development builds don't.

The SDK runs free in dev — localhost, `NODE_ENV=test`, debug builds, or
the `DVAI_FORCE_DEV=1` override. Licensing only matters at ship time.

The license is a single `.jwt` token. Your licensor mints it — you, or
whoever sells the SDK to you. The SDK ships only with the **public**
verification key. It can't mint tokens. It never phones home. Validation
runs fully offline.

One walkthrough per platform — pick yours:

- [Web](./web) — `@dvai-bridge/core` in the browser (Vite, Next.js, etc.).
- [Node](./node) — `@dvai-bridge/core` in Node, serverless, or Electron main.
- [iOS](./ios) — Swift apps via the `DVAIBridge` SwiftPM / CocoaPods package.
- [Android](./android) — Kotlin / Java apps via `co.deepvoiceai:dvai-bridge`.
- [.NET](./dotnet) — MAUI, Avalonia, WinUI, and console apps via the `DVAIBridge` NuGet family.
- [Flutter](./flutter) — `dvai_bridge` from pub.dev.
- [React Native](./react-native) — `@dvai-bridge/react-native` TurboModule on RN ≥ 0.77.
- [Capacitor](./capacitor) — `@dvai-bridge/capacitor` hybrid apps.

## What every platform has in common

1. The license is one JWT — a single line of base64url text. It carries
   the licensee name, the expiry, the allowed platforms, and an
   audience binding (your domain or bundle id). The signature is ECDSA
   P-256 (ES256).
2. The SDK looks at a platform-default path first — `dvai-license.jwt`
   in your project root on Node, `/dvai-license.jwt` from your origin
   on the web. Override it with a config field or an environment
   variable.
3. Dev mode ignores license problems. Production throws
   `LicenseRequiredError` (or the native equivalent) before any
   inference runs. The message points you at the fix.

## Where to get a license

If you consume the SDK, your licensor hands you the file. Drop it at
the discovery path the platform page calls out. Ship your app.

If you run your own DVAI-Bridge fork or private build, mint your own.
Generate a keypair once with
`node scripts/license/generate-keypair.mjs`. Commit the public key into
`packages/dvai-bridge-core/src/license/publicKeys.ts`. Store the
private key in your secrets manager. Use it inside your
license-generator service to mint customer JWTs. The script prints
each step inline.

## Dev-mode bypass at a glance

The SDK silences license checks when **any** of these are true:

- `NODE_ENV=test` or `NODE_ENV=development` (Node)
- `DVAI_FORCE_DEV=1` (any platform with process env)
- `localhost`, `127.0.0.1`, `*.local`, or RFC1918 hostnames (browser)
- `Capacitor.DEBUG === true` (Capacitor hybrid)
- `localStorage.DVAI_FORCE_DEV = "true"` (browser test hook)

`DVAI_FORCE_PROD=1` overrides every signal above. Use it to rehearse
the production code path locally.

## Inspecting license status without booting the SDK

Want to display the licensee, expiry, or tier without the full cost of
`DVAI.initialize()` / `DVAIBridge.start()`? Run the validator
standalone. The `LicenseValidator` class is part of every SDK's public
surface.

[Pre-init license inspection →](./pre-init-inspection)
