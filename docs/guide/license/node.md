# License setup — Node

You imported `@dvai-bridge/core` in a Node script, Next.js server route,
serverless function, or Electron main process. Here's the path from
zero to a license-enforced production build.

## TL;DR

Place `dvai-license.jwt` at your project root (next to `package.json`).
The SDK reads it automatically on `initialize()`. In production, the
SDK throws `LicenseRequiredError` if the file is missing or invalid;
in `NODE_ENV=development` or `NODE_ENV=test` the check is skipped.

## Where the file goes

In priority order:

1. Inline JWT — `new DVAI({ licenseToken: "..." })`
2. Explicit path — `new DVAI({ licenseKeyPath: "/etc/dvai/license.jwt" })`
3. `DVAI_LICENSE_PATH` environment variable
4. `DVAI_LICENSE_TOKEN` environment variable (inline JWT)
5. Auto-discovery — `dvai-license.jwt` in `process.cwd()`, then one
   level up (handy for monorepos where you `cd packages/myapp` and
   `node ./dist/server.js`)

For containerised deployments, point `DVAI_LICENSE_PATH` at a mounted
secret (Kubernetes secret, Docker `--secret`, etc.) — the SDK reads
the file once at startup, then never touches it again.

## Code: with vs. without

Default discovery (Node finds `./dvai-license.jwt`):

```ts
import { DVAI } from "@dvai-bridge/core";

const dvai = new DVAI({ backend: "transformers" });
await dvai.initialize();
console.log(dvai.licenseStatus); // { kind: "commercial", licensee: ... }
console.log(dvai.baseUrl);        // http://127.0.0.1:38883/v1
```

Inline JWT (CI / serverless friendly):

```ts
const dvai = new DVAI({
  backend: "transformers",
  licenseToken: process.env.DVAI_LICENSE_JWT,
});
await dvai.initialize();
```

Explicit path:

```ts
const dvai = new DVAI({
  backend: "transformers",
  licenseKeyPath: "/run/secrets/dvai-license.jwt",
});
```

Via environment variable (no code changes):

```bash
DVAI_LICENSE_PATH=/run/secrets/dvai-license.jwt node ./server.js
# or
DVAI_LICENSE_TOKEN=$(cat license.jwt) node ./server.js
```

## What happens without a license

In production, `initialize()` throws `LicenseRequiredError` before any
backend loads. The error message tells you exactly which check failed.

```ts
import { DVAI, LicenseRequiredError } from "@dvai-bridge/core";

try {
  await dvai.initialize();
} catch (err) {
  if (err instanceof LicenseRequiredError) {
    console.error(err.message);
    console.error("status:", err.status.kind); // "free-prod" | "free-expired"
    process.exit(1);
  }
  throw err;
}
```

A typical message looks like:

```
DVAI-Bridge Commercial License Required
=======================================

no license token found; checked config.licenseToken,
config.licenseKeyPath, DVAI_LICENSE_PATH env, DVAI_LICENSE_TOKEN env,
and platform-default paths

This SDK is licensed under BSL 1.1 and requires a valid commercial
or trial license to run in production / release builds.
... (resolution steps)
```

## Testing locally without a license

Three ways:

```bash
# 1. NODE_ENV=test or NODE_ENV=development — most natural for tests.
NODE_ENV=test node ./tests/run.js

# 2. Explicit override — for ad-hoc local runs.
DVAI_FORCE_DEV=1 node ./server.js

# 3. Use a `dvai-license.jwt` file (real or sample from the
#    generate-keypair script's output).
```

To rehearse production behaviour locally, set `DVAI_FORCE_PROD=1`. It
overrides every dev-mode signal and makes the SDK throw if the license
is missing.

## Audience binding for servers

Server-side Node deployments don't have a browser hostname, so the SDK
needs you to tell it which `aud` claim to match:

```bash
DVAI_AUDIENCE=api.acme.com node ./server.js
```

If `DVAI_AUDIENCE` is unset, the SDK accepts any license whose `aud`
claim contains `"*"` (the any-host wildcard), but refuses ones bound to
specific domains. Most commercial licenses include `"*"` so this works
out of the box; bind explicitly with `DVAI_AUDIENCE` if you want
stricter checks.

## When validation fails

Common Node-specific failures:

| Error reason fragment | What's wrong | Fix |
| --- | --- | --- |
| `no license token found` | File missing at all 5 discovery paths | Drop one in, or set `DVAI_LICENSE_PATH` |
| `does not authorise platform "node"` | License doesn't include `"node"` in `platforms` | Re-issue covering node |
| `audience entries ... do not match` | `DVAI_AUDIENCE` doesn't match any `aud` entry | Set `DVAI_AUDIENCE` or use a `*` license |

## See also

- [License setup index](./index)
- [Pre-init inspection](./pre-init-inspection) — run `LicenseValidator`
  standalone in a script / CLI / health endpoint without booting the
  backend.
- [Web](./web) — browser-side flow.
- [Reference: DVAIConfig.licenseKeyPath / licenseToken](/reference/api).
