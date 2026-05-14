# License setup — Web

You just ran `pnpm add @dvai-bridge/core` and want to ship to a real
domain. Here's everything you need.

## TL;DR

Drop your `dvai-license.jwt` file into your app's static-assets folder
(`public/` for Vite, Next.js, CRA; `static/` for SvelteKit) and ship.
The SDK fetches `/dvai-license.jwt` from the same origin at startup,
verifies the signature offline, and unlocks production behaviour. On
localhost, the SDK ignores license problems entirely.

## Where the file goes

Default (auto-discovered): your origin must serve the file at the URL
`/dvai-license.jwt`. For most bundlers that means putting it in the
static-assets folder:

| Framework | Drop the file at |
| --- | --- |
| Vite (React, Vue, Svelte, vanilla) | `public/dvai-license.jwt` |
| Next.js | `public/dvai-license.jwt` |
| Create React App | `public/dvai-license.jwt` |
| SvelteKit | `static/dvai-license.jwt` |
| Astro | `public/dvai-license.jwt` |
| Webpack (no plugin) | whatever path your `output.publicPath` resolves to |

Verify by hitting `https://<your-domain>/dvai-license.jwt` in a browser
— you should see the JWT text. If your edge / CDN strips unknown file
extensions, register `.jwt` as `text/plain` or `application/jwt`.

## Code: with vs. without

Without a license (development, localhost):

```ts
import { DVAI } from "@dvai-bridge/core";

const dvai = new DVAI({
  backend: "auto",
  modelId: "Llama-3.2-1B-Instruct-Q4_K_M",
});

await dvai.initialize();
// On localhost: dvai.licenseStatus.kind === "free-dev"
```

With a license (production, default discovery):

```ts
// Same code as above. Nothing changes.
// As long as /dvai-license.jwt is served from the same origin,
// dvai.licenseStatus.kind will be "commercial" or "trial" after init.
```

With a license at a non-default path:

```ts
const dvai = new DVAI({
  backend: "auto",
  modelId: "Llama-3.2-1B-Instruct-Q4_K_M",
  licenseKeyPath: "/assets/dvai-license.jwt", // any same-origin URL
});
```

With the JWT injected inline (env var, CI secret, etc.):

```ts
const dvai = new DVAI({
  backend: "auto",
  modelId: "Llama-3.2-1B-Instruct-Q4_K_M",
  licenseToken: import.meta.env.VITE_DVAI_LICENSE_JWT,
});
```

`licenseToken` always wins over `licenseKeyPath`, which wins over
auto-discovery.

## What happens without a license

In production (any non-localhost origin), `initialize()` throws
`LicenseRequiredError`:

```ts
import { DVAI, LicenseRequiredError } from "@dvai-bridge/core";

try {
  await dvai.initialize();
} catch (err) {
  if (err instanceof LicenseRequiredError) {
    // err.message is verbose — points at the discovery paths and
    // the dev-mode bypass list.
    // err.status.kind is "free-prod" or "free-expired".
    console.error(err.message);
  }
}
```

The error message includes the resolution steps inline; surface it in
your error reporter (Sentry, console, server log) and you'll see
exactly which check failed.

## Testing locally without a license

You don't have to do anything — `localhost`, `127.0.0.1`, `*.local`,
and RFC1918 hostnames all auto-detect as dev mode. The SDK will start
and log `licenseStatus.kind === "free-dev"`.

If you serve your dev build from a non-localhost host (e.g. a real
DNS name behind ngrok), force dev mode explicitly:

```ts
// Pick one of these before DVAI's first initialize():
window.localStorage.setItem("DVAI_FORCE_DEV", "true");
```

To rehearse production behaviour on localhost:

```ts
window.localStorage.setItem("DVAI_FORCE_PROD", "true");
```

## When validation fails

Common failures and what they mean:

| Error reason fragment | What's wrong | Fix |
| --- | --- | --- |
| `not a well-formed JWT` | File is empty, truncated, or HTML 404 page | Verify `/dvai-license.jwt` returns the raw token |
| `unsupported alg` | Token signed with the wrong algorithm | Re-issue with ES256 |
| `kid ... is not in the SDK's public-key registry` | You're on an old SDK that pre-dates a key rotation | Upgrade `@dvai-bridge/core` |
| `signed with the placeholder key` | You're using a development SDK that hasn't shipped a real key | Replace `publicKeys.ts` with your generated key |
| `signature did not verify` | Token was tampered with or wrong key | Re-download from your licensor |
| `does not authorise platform "web"` | License doesn't include `"web"` in its `platforms` claim | Re-issue covering web |
| `audience entries ... do not match` | Token bound to a different hostname | Re-issue with the right `aud`, or use a `*.your-domain.com` wildcard |
| `expired` | Past `exp` | Renew |

Every reason is logged to `console` when validation fails, even when
the SDK throws.

## See also

- [License setup index](./index) — cross-platform summary.
- [Node](./node) — server-side validation flow.
- [Reference: DVAIConfig.licenseKeyPath / licenseToken](/reference/api).
