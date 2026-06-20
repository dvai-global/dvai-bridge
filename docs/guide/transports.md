# Transports

## What does this do?

The same call — `dvai.initialize()` — has to expose an OpenAI HTTP API
inside a browser tab, a Node process, an Android APK, and an iOS app.
None of those allow exactly the same thing. The transport layer is the
glue that picks the right approach per runtime.

You don't have to touch it. The default (`transport: "auto"`) does the
right thing — browsers get MSW, every other runtime gets a real HTTP
server on `127.0.0.1:38883`, and you just read `dvai.baseUrl`. The rest
of this page is for the cases when you need to override — forcing MSW
in tests, picking a different port, dealing with CORS or Private Network
Access.

```ts
// Default — picks MSW or HTTP automatically.
const dvai = new DVAI({});

// Force MSW (browser only — fails elsewhere):
new DVAI({ transport: "msw" });

// Force HTTP (Node only — fails in the browser):
new DVAI({ transport: "http", httpBasePort: 40000 });
```

## How selection works

When you call `dvai.initialize()` (JS/TS) or `start()` on a native SDK,
the library picks one of three transports.

| Transport | When it's used | What it does |
|---|---|---|
| `msw` | Browser main thread (JS/TS) | Registers an MSW service worker that intercepts fetch calls to an OpenAI-shaped URL. No actual server. |
| `http` | Node, Electron main, Capacitor mobile, native iOS / Android / .NET | Boots a real HTTP server on `127.0.0.1` starting at port `38883`, serves `/v1/*` endpoints. |
| `none` | Web Workers, Service Workers, or when you opt out | No transport started. Use `dvai.chatCompletion()` directly. |

Read the endpoint via `dvai.baseUrl` (JS) — or the equivalent field on
each native SDK's `start()` return value.

- MSW path — `"https://api.openai.local/v1"` (or whatever you set via `mockUrl`).
- HTTP path — `"http://127.0.0.1:38883/v1"` (or the fallback port if 38883 was busy).

## Port fallback

If the base port is taken, `dvai-bridge` retries `38884`, `38885`, and so
on — up to 16 attempts. If all are busy, `initialize()` or `start()`
throws with an actionable error listing the tried range.

Override the base port or attempts limit.

```ts
new DVAI({ httpBasePort: 40000, httpMaxPortAttempts: 4 });
```

Native SDKs accept the same settings on their start options.

## Overriding the transport (JS / TS)

Usually you don't need to. If you do:

```ts
new DVAI({ transport: "msw" });   // force MSW (browser only)
new DVAI({ transport: "http" });  // force HTTP (Node / Electron main only)
new DVAI({ transport: "none" });  // no transport; direct inference only
```

Native SDKs always use HTTP. There's no MSW analogue outside the browser
main thread.

## CORS and Private Network Access

The HTTP transport emits CORS and PNA headers on every response — so
HTTPS pages and webviews can call loopback without being blocked by
Chrome or Edge Private Network Access enforcement. Configure the allowed
origin.

```ts
new DVAI({ corsOrigin: "*" });                                    // default
new DVAI({ corsOrigin: "https://app.example.com" });              // exact origin
new DVAI({ corsOrigin: ["https://a.com", "https://b.com"] });     // allowlist
```

Native SDKs expose `corsOrigin` on their start options with the same
semantics. Every platform's HTTP implementation writes the same headers
on every response.

## Mobile (Android cleartext policy)

Android 9+ blocks cleartext HTTP by default. The Capacitor plugin
(`@dvai-bridge/capacitor`), the Android AAR
(`co.deepvoiceai:dvai-bridge`), and the React Native and Flutter
wrappers that consume them all inject a minimal
`network_security_config.xml` entry via Gradle manifest merging. You
don't touch the config file by hand.

For reference — this is what gets merged in.

```xml
<network-security-config>
  <domain-config cleartextTrafficPermitted="true">
    <domain includeSubdomains="true">localhost</domain>
    <domain>127.0.0.1</domain>
  </domain-config>
</network-security-config>
```

**iOS has no equivalent step.** Apple's App Transport Security (ATS)
exempts loopback (`127.0.0.1`, `::1`, `localhost`) by default — no
`Info.plist` entries needed, no NSExceptionDomains.

## Why plain HTTP on loopback (not HTTPS)

Public CAs won't issue certs for `127.0.0.1` or `localhost`. Self-signed
certs fail iOS ATS and Android NSC trust-anchor validation by default —
and accepting them means opting out of cert validation app-wide. That's
*worse* security-wise than allowing cleartext to loopback only.

Every mainstream hybrid framework — Capacitor, Cordova, Ionic, Expo,
React Native dev server — goes plain HTTP on loopback. We do the same.

Your app's traffic to the outside world still uses HTTPS. Only the
in-process `localhost` → `localhost` hop is cleartext, and it never
leaves the device.
