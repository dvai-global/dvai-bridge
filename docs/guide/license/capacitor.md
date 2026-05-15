# License setup — Capacitor

You added `@dvai-bridge/capacitor` (plus a backend plugin like
`@dvai-bridge/capacitor-llama`) and want to ship to the App Store and
Play Store. Here's the licensing path.

## TL;DR

Drop `dvai-license.jwt` into your `www/` (or Vite's `public/`) folder
so it ends up at `/dvai-license.jwt` inside the bundled webview
assets. The JS-side validator runs on `DVAIBridge.start(...)`, fetches
the file via the Capacitor scheme, verifies the signature offline,
and unlocks production behaviour. In `Capacitor.DEBUG === true` mode
the SDK ignores license problems.

## Where the file goes

For Capacitor, the JS-side validator does the verification — same
discovery rules as the [web setup](./web), but the file ships inside
the native app rather than from your origin.

- **Vite / esbuild bundled webview**: drop the file in `public/`. Vite
  copies it to `dist/`, then `npx cap sync` copies `dist/` into the
  native projects.
- **Single-HTML / no bundler**: drop it directly into `www/`.

Verify it's bundled correctly:

- iOS: open the `.app` bundle in Xcode, expand `App/public/`, confirm
  `dvai-license.jwt` is there.
- Android: open the APK with Android Studio's APK analyzer, look for
  `assets/public/dvai-license.jwt`.

Alternative discovery (same as web):

1. Inline JWT — `DVAIBridge.start({ licenseToken: "..." })`.
2. Explicit URL — `DVAIBridge.start({ licenseKeyPath: "/path/in/webview.jwt" })`.

## Code: with vs. without

Default (license bundled in webview assets):

```ts
import { DVAIBridge } from "@dvai-bridge/capacitor";

const bound = await DVAIBridge.start({
  backend: "llama",
  modelPath: modelPath,
});

console.log(bound.baseUrl);          // http://127.0.0.1:38883/v1
console.log(bound.licenseStatus);    // { kind: "commercial", licensee: "Acme", ... }
```

With an inline JWT (downloaded into Capacitor Preferences):

```ts
import { Preferences } from "@capacitor/preferences";

const { value: token } = await Preferences.get({ key: "dvai_license_jwt" });

const bound = await DVAIBridge.start({
  backend: "llama",
  modelPath,
  licenseToken: token!,
});
```

## What happens without a license

In release builds, `start(...)` rejects with a `LicenseRequiredError`
relayed across the Capacitor bridge:

```ts
try {
  await DVAIBridge.start(...);
} catch (err: any) {
  if (err.code === "LICENSE_REQUIRED" || err.name === "LicenseRequiredError") {
    // err.message is a multi-line string; err.status.kind is the kind.
    console.error(err.message);
    showAlert("License required");
  }
}
```

## Testing locally without a license

The Capacitor JS validator detects dev mode when **any** of these are
true:

- The webview hostname is `localhost` (which it usually is in
  Capacitor's bundled-content scheme).
- `Capacitor.DEBUG === true` (set by Capacitor in debug builds).
- `window.localStorage.DVAI_FORCE_DEV === "true"`.
- `NODE_ENV=test` or `NODE_ENV=development` at bundle time.

To rehearse production behaviour locally:

```ts
localStorage.setItem("DVAI_FORCE_PROD", "true");
```

## Audience binding on Capacitor

The runtime audience is the webview hostname — Capacitor reports
`localhost` for the bundled-content origin. Your licenses should
include `"localhost"` as an `aud` entry for Capacitor activation, or
use `"*"`. (The native bundle-id binding will come with the v3.3
native-side validators — see the iOS / Android pages.)

## When validation fails

| Error reason fragment | What's wrong | Fix |
| --- | --- | --- |
| `not a well-formed JWT` | File missing from `www/public` after `cap sync` | Re-run `cap sync` after the file is in `public/` |
| `signature did not verify` | Wrong key or tampered | Re-download from your licensor |
| `does not authorise platform "capacitor"` | License missing `"capacitor"` in `platforms` | Re-issue covering Capacitor |
| `audience entries ... do not match "localhost"` | License doesn't include `localhost` (or `*`) | Re-issue with `localhost` in `aud` |
| `expired` | Past `exp` | Renew |

## See also

- [License setup index](./index)
- [Pre-init inspection](./pre-init-inspection) — run
  `LicenseValidator` from `@dvai-bridge/core` in the webview before
  the native plugin boots, useful for setup wizards.
- [Web](./web) — the JS-side discovery rules apply identically.
- [Native LLM (Capacitor)](/guide/native-backend) — the broader
  Capacitor quickstart.
