# DVAI Hub — developer fork

DVAI Hub ships in two flavors:

| Flavor | Audience | Distribution |
|---|---|---|
| **Flavor 1 — first-party Hub** | End users with multiple devices | GitHub Releases / Homebrew / winget under the `DeepVoiceAI` brand. |
| **Flavor 2 — app-developer fork** | App developers who want a *branded* desktop companion alongside their mobile app | Forked, rebranded, locked to one `appId`, distributed by you. |

This guide is the user-facing summary of Flavor 2. The full
step-by-step lives next to the source at
[`hub/DEVELOPER-FORK.md`](https://github.com/dvai-global/dvai-bridge/blob/main/hub/DEVELOPER-FORK.md).

---

## When to fork

Fork the Hub when you want all of these:

- Your desktop companion **branded as your app**
  ("Acme Hub", not "DVAI Hub").
- Pairing **locked to your specific** mobile app's bundle id.
- Distribution through **your own** channel (your DMG / MSI /
  Homebrew tap / winget package).

If you only want one of those, skip the fork — point your users
at upstream DVAI Hub instead.

---

## What you inherit

Every Phase 4 capability:

- LAN mDNS discovery + HMAC-signed pairing handshake.
- Capability probe + offload decider.
- Multi-tenant pairing layer (locked to your appId via
  `multiTenant: { allowedAppIds: ["com.your.app"] }`).
- Strict-by-default substitution policy with the `preferBetterQuant`
  per-pairing opt-in.
- The external-engine bridge framework so users with Ollama or
  LM Studio installed can route through your branded companion.
- Per-app audit log with 30-day rolling retention.
- Tauri 2 desktop shell with system tray, single-instance lock,
  auto-start hook, and notifications.

---

## What you replace

Three brand surfaces and the pairing lock:

1. **`hub/src-tauri/tauri.conf.json`** — `productName`, `identifier`,
   bundle metadata.
2. **`hub/src/App.tsx`** + **`hub/src/styles.css`** — visible brand
   text + colors.
3. **`hub/src-tauri/icons/`** — full icon set (run
   `pnpm dlx @tauri-apps/cli icon` to generate from a 1024×1024
   master).
4. **`hub/peer-mode/server.ts`** — set `multiTenant.allowedAppIds`
   to your bundle id(s).

---

## What you cannot opt out of

The upstream Hub commits to a few invariants that protect end users
and you cannot disable in a fork:

- The strict-by-default substitution policy.
- Per-app pairing isolation (even when locked to one appId, the
  audit log groups by appId for forensic clarity).
- The 30-day pairing inactivity TTL.
- LAN-only by default. Rendezvous URL is opt-in per fork.

If your fork loosens any of these, you should rename it — it's no
longer a "DVAI Hub-compatible" build.

---

## Distribution

Your responsibility — typically:

- Apple Developer ID + macOS notarization for the `.dmg`.
- Windows code-signing cert for the `.msi`.
- Your own GitHub Releases workflow (the upstream
  [`dvai-hub-release.yml`](https://github.com/dvai-global/dvai-bridge/blob/main/.github/workflows/dvai-hub-release.yml)
  is a template).
- Optional: your own Homebrew tap; a separate winget manifest
  submission.

The upstream packaging templates in
[`hub/packaging/`](https://github.com/dvai-global/dvai-bridge/tree/main/hub/packaging)
work as starting points — replace identifier, URL, and brand fields.

---

## Upstream merges

DVAI Hub will receive new versions over time (security patches,
new external engine adapters, performance improvements). Pull from
upstream and rebase your branding on top:

```bash
git fetch dvai-bridge main
git merge -X subtree=hub dvai-bridge/main -m "merge upstream DVAI Hub"
```

Branding files (steps 1–3 above) will sometimes conflict — resolve
in favor of your branding. The Phase 4 spec deliberately keeps brand
strings centralized so these conflicts are small and predictable.

---

## See also

- [Full step-by-step at `hub/DEVELOPER-FORK.md`](https://github.com/dvai-global/dvai-bridge/blob/main/hub/DEVELOPER-FORK.md)
- [DVAI Hub user guide](/guide/dvai-hub)
- [Migration v3.0 → v3.1](/migration/v3.0-to-v3.1)
