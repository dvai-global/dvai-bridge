# Transports

`dvai-bridge` exposes a single OpenAI-compatible HTTP surface on every
platform — the transport under that surface is selected automatically
based on the runtime environment.

## How selection works

When you call `dvai.initialize()`, the library picks one of three
transports:

| Transport | When it's used | What it does |
|---|---|---|
| `msw` | Browser main thread | Registers an MSW service worker that intercepts fetch calls to an OpenAI-shaped URL. No actual server. |
| `http` | Node / Electron main process | Boots a real `http.createServer` on `127.0.0.1` starting at port `38883`, serves `/v1/*` endpoints. |
| `none` | Web Workers, Service Workers, or when you opt out | No transport started. Use `dvai.chatCompletion()` directly. |

You read the endpoint via `dvai.baseUrl`:

- MSW path: `"https://api.openai.local/v1"` (or whatever you set via `mockUrl`).
- HTTP path: `"http://127.0.0.1:38883/v1"` (or the fallback port if 38883 was busy).

## Port fallback

On HTTP, if the base port is taken, `dvai-bridge` retries `38884`, `38885`,
... up to 16 attempts. If all are in use, `initialize()` throws with an
actionable error listing the tried range.

Override the base port or attempts limit:

```ts
new DVAI({ httpBasePort: 40000, httpMaxPortAttempts: 4 });
```

## Overriding the transport

Usually you don't need to. If you do:

```ts
new DVAI({ transport: "msw" });   // force MSW (browser only)
new DVAI({ transport: "http" });  // force HTTP (Node only)
new DVAI({ transport: "none" });  // no transport; direct inference only
```

## CORS and Private Network Access

The HTTP transport emits CORS + PNA headers on every response so
HTTPS pages can call loopback without being blocked by Chrome's
Private Network Access enforcement. Configure the allowed origin:

```ts
new DVAI({ corsOrigin: "*" });                        // default
new DVAI({ corsOrigin: "https://app.example.com" });  // exact origin
new DVAI({ corsOrigin: ["https://a.com", "https://b.com"] }); // allowlist
```

## Mobile (Android NSC)

Android 9+ blocks cleartext HTTP by default. For Capacitor / React
Native / native apps using the HTTP transport on loopback, add a
network-security-config allowing cleartext for `127.0.0.1`:

```xml
<network-security-config>
  <domain-config cleartextTrafficPermitted="true">
    <domain includeSubdomains="true">localhost</domain>
    <domain>127.0.0.1</domain>
  </domain-config>
</network-security-config>
```

In later phases, the Capacitor plugin and Android AAR will inject this
automatically via their Gradle scripts. iOS has no equivalent step —
ATS exempts loopback by default.
