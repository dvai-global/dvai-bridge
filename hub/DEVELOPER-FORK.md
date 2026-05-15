# DVAI Hub — Developer Fork Guide

DVAI Hub ships in two flavors:

| Flavor | Audience | Rendezvous |
|---|---|---|
| **Flavor 1 — first-party Hub** | End users with multiple devices | Distributed via GitHub Releases / Homebrew / winget under the `DeepVoiceAI` brand. |
| **Flavor 2 — app-developer fork** | App developers who want a *branded* desktop companion alongside their mobile app | Forked, rebranded, locked to one `appId`, distributed by you. |

This guide walks an app developer through Flavor 2.

---

## Why fork?

If you ship a mobile app on `dvai-bridge` and want a desktop companion that:
- Is **branded as your app** ("Acme Hub", not "DVAI Hub")
- Only accepts pairings from **your specific** mobile app
- Lives in **your** distribution channel (your DMG, your MSI, your tap)

…then forking the Hub is the right choice. You inherit every Phase 4
capability (LAN discovery, pairing isolation, model substitution,
external engine bridge, audit log) without reimplementing it.

If you'd rather just have your users install the upstream DVAI Hub,
no fork is needed — they `brew install dvai-hub` and your app pairs
with whatever's already running.

---

## Step-by-step

### 1. Fork the `hub/` directory into your repo

```bash
# In your app's repo:
git remote add dvai-bridge https://github.com/dvai-global/dvai-bridge
git fetch dvai-bridge main
git read-tree --prefix=hub/ -u dvai-bridge/main:hub
```

…or copy the directory manually if you'd rather not vendor it as a
subtree. Either way, you now own the source.

### 2. Replace branding

Three files carry the upstream brand:

**`hub/src-tauri/tauri.conf.json`**
```jsonc
{
  "productName": "Acme Hub",
  "identifier": "com.acme.hub",   // your reverse-DNS bundle id
  // ...
  "bundle": {
    "copyright": "Copyright © 2026 Acme Inc.",
    "shortDescription": "Acme companion for desktop offload"
  }
}
```

**`hub/src/App.tsx`** — the brand block at the top of the rail:
```tsx
<div className="brand">
  <h1>Acme Hub</h1>
  <span className="version">v1.0.0</span>
</div>
```

**`hub/src/styles.css`** — the `--accent` color (and any other tokens).

### 3. Replace icons

Drop your icon set into `hub/src-tauri/icons/`:
- `icon.ico` (Windows)
- `icon.icns` (macOS)
- `icon.png` + `32x32.png` + `128x128.png` (Linux + tray)

You can generate them all from a 1024×1024 source PNG with the Tauri
icon helper (run from the `hub/` directory):

```bash
pnpm dlx @tauri-apps/cli icon path/to/your-1024.png
```

### 4. Lock to your app's bundle id

Edit `hub/peer-mode/server.ts` to restrict pairings to your appId:

```ts
const peerOptions: PeerModeOptions = {
  storeDir: STORE_DIR,
  externalEnginesEnabled: true,
  multiTenant: { allowedAppIds: ["com.acme.app"] },  // <-- your bundle id
  onPairingRequest: (request) => awaitPairingApproval(request),
  // ...
};
```

The `MultiTenantPairing` layer rejects any pairing request whose
`appId` is not in this list **before** the user is even prompted.

If you also ship a tablet variant or a free/paid SKU with a different
bundle id, list all of them.

### 5. Set up your release pipeline

The upstream `.github/workflows/dvai-hub-release.yml` is a template you
can copy into your repo. You'll need to provide your own:

- Apple Developer ID + signing cert + notarization credentials
- Windows code-signing cert (e.g. DigiCert, Sectigo)
- Repo secrets matching the names in the workflow

A sister doc, `HUB-SIGNING-CERTS.md`, documents the procurement and
rotation process. Keep it gitignored if it contains anything sensitive
(it shouldn't — it's process docs, not the certs themselves).

### 6. (Optional) Distribute through your own tap / package

For Homebrew, create a tap repo under your org:
```
github.com/your-org/homebrew-acme-hub
└── Formula/acme-hub.rb     # adapted from hub/packaging/homebrew/dvai-hub.rb
```

For winget, submit a manifest to `microsoft/winget-pkgs`:
```
manifests/a/Acme/AcmeHub/1.0.0/Acme.AcmeHub.installer.yaml
```

Both manifests in `hub/packaging/` work as starting points — replace
the identifier, URL, and brand fields.

---

## Upstream merges

DVAI Hub will receive new versions over time (new external engine
adapters, security patches, performance improvements). Keep your fork
in sync:

```bash
git fetch dvai-bridge main
git merge -X subtree=hub dvai-bridge/main -m "merge upstream DVAI Hub"
```

The branding files (steps 2–4 above) will sometimes conflict — resolve
in favor of your branding. The Phase 4 spec deliberately keeps brand
strings centralized so these conflicts are small and predictable.

---

## What you cannot opt out of

The upstream Hub commits to a few invariants that protect end users
and you cannot disable in a fork:

- The strict-by-default substitution policy (no silent type / family
  / size mismatches)
- Per-app pairing isolation (even when locked to one appId, the
  per-tenant audit log still groups by appId for forensic clarity)
- The 30-day pairing inactivity TTL (re-handshake required)
- LAN-only by default (rendezvous URL is opt-in per fork)

If your fork loosens any of these, it's no longer a "DVAI Hub-compatible"
build and you should rename it accordingly.

---

## Questions?

Open a discussion at
[github.com/dvai-global/dvai-bridge/discussions](https://github.com/dvai-global/dvai-bridge/discussions)
or file an issue tagged `[hub-fork]` — we're glad to hear from
downstream forks and to clean up rough edges this guide misses.
