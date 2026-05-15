# License setup

DVAI-Bridge is licensed under BSL 1.1. In **production** builds, the SDK
needs a signed license JWT to start. In **development** (localhost,
`NODE_ENV=test`, debug builds, the `DVAI_FORCE_DEV=1` override), the SDK
runs without one — you only ever need to think about licensing at the
point you ship.

The license file is a single `.jwt` token issued by the operator of the
SDK (you, or whoever sells the SDK to you). The SDK ships only with the
**public** verification key; it cannot mint tokens itself, and it does
not phone home. Validation is fully offline.

This section has a one-page walkthrough per platform. Pick yours:

- [Web](./web) — `@dvai-bridge/core` running in the browser (Vite,
  Next.js, etc.).
- [Node](./node) — `@dvai-bridge/core` running in Node, serverless, or
  Electron main.
- [iOS](./ios) — Swift apps via the `DVAIBridge` SwiftPM / CocoaPods
  package.
- [Android](./android) — Kotlin / Java apps via
  `co.deepvoiceai:dvai-bridge`.
- [.NET](./dotnet) — MAUI, Avalonia, WinUI, and console apps via the
  `DVAIBridge` NuGet family.
- [Flutter](./flutter) — `dvai_bridge` from pub.dev.
- [React Native](./react-native) — `@dvai-bridge/react-native`
  TurboModule on RN ≥ 0.77.
- [Capacitor](./capacitor) — `@dvai-bridge/capacitor` hybrid apps.

## What every platform has in common

1. The license file is a single JWT (one line of base64url text). It
   contains the licensee name, expiry, allowed platforms, and an
   audience binding (your domain or bundle id). The signature is
   ECDSA P-256 (ES256).
2. The SDK looks for the file at a platform-default location first
   (e.g. `dvai-license.jwt` in your project root for Node, or
   `/dvai-license.jwt` served from your origin for the web). You can
   override that with a config field or an environment variable.
3. In dev mode the SDK ignores license problems. In production it
   throws `LicenseRequiredError` (or the native equivalent) before any
   inference happens, with a verbose message pointing you at the fix.

## Where to get a license

If you're an SDK consumer, your licensor (the operator that issued
your build) hands you the file. Drop it at the discovery path the
platform page calls out, ship your app.

If you're operating your own DVAI-Bridge fork or a private build,
generate your keypair once with
`node scripts/license/generate-keypair.mjs`, commit the public key
into `packages/dvai-bridge-core/src/license/publicKeys.ts`, store the
private key in your secrets manager, and use it inside your
license-generator service to mint customer JWTs. The script's output
explains each step inline.

## Dev-mode bypass at a glance

The SDK silences license checks when **any** of these are true:

- `NODE_ENV=test` or `NODE_ENV=development` (Node)
- `DVAI_FORCE_DEV=1` (any platform that has process env)
- `localhost`, `127.0.0.1`, `*.local`, or RFC1918 hostnames (browser)
- `Capacitor.DEBUG === true` (Capacitor hybrid)
- `localStorage.DVAI_FORCE_DEV = "true"` (browser test hook)

Setting `DVAI_FORCE_PROD=1` overrides all of the above — useful when
you want to test the production code path locally.

## Inspecting license status without booting the SDK

If your host app wants to display the licensee, expiry, or tier
without paying the full cost of `DVAI.initialize()` /
`DVAIBridge.start()`, you can run the validator standalone — the
`LicenseValidator` class is part of every SDK's public surface.

[Pre-init license inspection →](./pre-init-inspection)
