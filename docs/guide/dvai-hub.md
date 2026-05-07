# DVAI Hub

DVAI Hub is the household-utility flavor of distributed inference.
Run it on the strongest machine in your house — a desktop, a laptop
when it's plugged in, the family Mac mini — and any number of
dvai-bridge-powered mobile apps will pair with it and offload
heavy inference requests onto it.

You don't have to use it. Mobile apps still work standalone. But
when you do use it:

- Phone-class models that are slow on your phone (or burn through
  battery, or evict mid-generation) become snappy.
- A single household Hub serves multiple unrelated mobile apps from
  multiple family members; their pairings, caches, and audit logs
  stay isolated per-app.
- External engines you already have running (Ollama, LM Studio,
  vLLM, llama-server, llamafile) become available to those apps —
  no need for the apps to re-download a model the engine already
  has cached.

[Architecture deep-dive →](#how-it-works)
[Developer-fork guide →](/guide/dvai-hub-developer-fork)
[Migration: v3.0 → v3.1 →](/migration/v3.0-to-v3.1)

---

## Install

### macOS

```sh
brew install deepvoiceai/dvai-hub/dvai-hub
```

…or download the universal `.dmg` from
[GitHub Releases](https://github.com/Westenets/dvai-bridge/releases/latest).

### Windows

```powershell
winget install DeepVoiceAI.DVAIHub
```

…or download the `.msi` from
[GitHub Releases](https://github.com/Westenets/dvai-bridge/releases/latest).

### Linux

Download `.AppImage`, `.deb`, or `.rpm` from
[GitHub Releases](https://github.com/Westenets/dvai-bridge/releases/latest).

```sh
# AppImage
chmod +x DVAI-Hub-*.AppImage
./DVAI-Hub-*.AppImage

# Debian / Ubuntu
sudo apt install ./dvai-hub_*_amd64.deb

# RPM
sudo dnf install ./dvai-hub-*.x86_64.rpm
```

---

## First run

On first launch, the Hub:

1. Starts the embedded HTTP server on a free port (defaults to the
   `38883` range; falls back if busy).
2. Begins advertising itself on your LAN via mDNS as a peer
   (`_dvai-bridge._tcp.local`).
3. Lives in your system tray. Clicking the tray icon opens the
   dashboard; closing the window leaves Hub running in the tray.

The dashboard's first-run wizard walks you through:

- **Engines:** does the Hub have permission to surface external
  engines (Ollama, LM Studio, ...)? Default off — you opt in tab
  by tab from the Engines tab afterwards.
- **Auto-start at login:** opt in here or later from Settings.

---

## Pair your phone

Open your dvai-bridge-powered mobile app on the same Wi-Fi network
as the Hub. The app's first inference request:

1. Triggers an mDNS handshake to your Hub.
2. Surfaces an **approval modal** in the Hub dashboard:
   _"iPhone wants to pair with this Hub on behalf of `<your-app>`."_
3. On approve, a 256-bit pairing key is generated and stored.
   Subsequent requests from the same phone are HMAC-signed with
   that key — no further prompts.

The pairing is per-app. If you install a different app, it
triggers its own approval prompt and gets its own key. Revoking
one app doesn't affect the others.

Pairings expire after 30 days of inactivity. Re-handshake is
silent if you re-approve.

---

## Use it

There's nothing to do. Once paired, your mobile app's inference
requests route to the Hub automatically, subject to the usual
offload rules:

- The Hub runs the request locally if it has the model cached.
- If the requested model isn't an exact match, the Hub may
  substitute a same-shape model with a different quantization
  (only when you've approved better-quant substitution per-app
  in Settings).
- If no compatible model is cached, the Hub returns a structured
  `no_capable_device` error — your mobile app's offload policy
  decides whether to fall back to local inference.

The mobile app's chat client (LangChain, OpenAI SDK, etc.) sees
a normal SSE-streamed response — same shape as if it had run
locally. The fact that the work happened on your laptop is
invisible at the wire.

---

## How it works

```
┌────────────────────┐                      ┌─────────────────┐
│  iPhone running    │ ── mDNS handshake ─→ │   DVAI Hub      │
│  Acme Chat App     │                      │   (laptop)      │
│                    │   /v1/chat/...       │                 │
│  dvai-bridge       │ ── HMAC-signed ────→ │  • peer-mode    │
│  in target=offload │      request         │  • multi-tenant │
│      mode          │ ←── SSE stream ────  │  • engine bridge│
└────────────────────┘                      └─────────────────┘
                                                ↓ (if external
                                                   engine has it)
                                            ┌─────────────────┐
                                            │   Ollama / LM   │
                                            │   Studio / vLLM │
                                            └─────────────────┘
```

The Hub is built on the same v3.0 distributed-inference primitives
that power any other dvai-bridge target — capability assessment,
LAN mDNS discovery, HMAC-signed pairing handshake, OpenAI-compat
proxy. What's new in v3.1:

- **Multi-tenant pairing isolation.** A single Hub serves many
  unrelated apps; each gets its own pairing key, capability
  cache, and audit log. The Flavor 2 (developer-fork) build
  locks to a single appId.
- **Strict substitution policy.** When a request asks for
  `gemma-4-E2B-q4-instruct` and the Hub has `gemma-4-E2B-q8-instruct`
  cached, the policy chooses: refuse (default), or substitute
  with explicit warning (per-pairing opt-in). No silent
  family / version / size / type mismatches.
- **External engine bridge.** Opt-in framework that surfaces
  Ollama / LM Studio / vLLM / llama-server / llamafile as
  additional backend pools. Each engine's cached models are
  parsed through the same canonical-name parser so the
  substitution policy can reason about them.

---

## Settings

| Setting | Default | Where |
|---|---|---|
| Port | 38883 | Settings tab |
| mDNS service name | `dvai-hub` | Settings (advanced) |
| Rendezvous URL | unset (LAN-only) | Settings |
| Model cache location | OS-specific cache dir | Settings |
| Auto-start at login | off | Settings |
| External engines master switch | off | Engines tab |
| Per-engine toggle | off | Engines tab |
| Per-app substitution policy | strict | Paired Apps tab |

---

## Privacy

- Hub-served requests **never** leave your network unless you
  configure a `rendezvousUrl` for the internet path.
- Audit logs live on disk in your user-data directory; nothing is
  transmitted to DeepVoiceAI.
- The Hub does not auto-update by default. Updates come through
  whatever distribution channel you installed from
  (Homebrew / winget / direct download).

---

## Troubleshooting

**My phone can't find the Hub.**
- Same Wi-Fi network? Same subnet?
- Corporate / school networks frequently block mDNS. Try a phone
  hotspot or your home router.
- Open the dashboard's Status tab — does it show a baseUrl?
  Visit `http://<hub-baseurl>/v1/dvai/health` from your phone's
  browser to confirm reachability.

**The pairing modal never appears.**
- Look for a tray notification. If notifications are disabled in
  your OS, the Hub falls back to surfacing the modal on the next
  dashboard open.
- Is the Hub paused? Check the tray icon; "Resume peer-mode" wakes
  the embedded HTTP server.

**An inference request returns `no_capable_device`.**
- Check the Models tab — is the requested model cached?
- Check the Engines tab — is the engine that has the model
  enabled?
- Check the per-app Substitution Policy in Paired Apps — is the
  app allowed to use a different quant?

[Full distributed-inference troubleshooting →](/development/distributed-inference-testing#troubleshooting)

---

## See also

- [Developer fork guide](/guide/dvai-hub-developer-fork) — branded companion for app developers.
- [Migration v3.0 → v3.1](/migration/v3.0-to-v3.1) — what's new since v3.0.
- [Distributed inference](/guide/distributed-inference) — the substrate Hub builds on.
- [Self-hosting rendezvous](/guide/self-hosting-rendezvous) — for the internet path.
