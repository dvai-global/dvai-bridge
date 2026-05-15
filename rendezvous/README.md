# dvai-bridge rendezvous server

A self-hostable WebSocket relay that pairs two devices running
[dvai-bridge](https://github.com/dvai-global/dvai-bridge) across different
networks via QR-scan, then relays AEAD-encrypted inference traffic
between them. Stateless beyond per-session memory; no database; no
auth tokens; no plaintext inference data ever passes through the
server.

This server is **optional**. dvai-bridge's LAN device-offload path
(via mDNS) works without it. Only deploy this if your app users need
to offload inference between devices on **different networks** — e.g.
phone on cellular, laptop on home Wi-Fi.

## One-click deploy

| Platform | Click to deploy | Notes |
|---|---|---|
| **Railway** | [![Deploy on Railway](https://railway.app/button.svg)](https://railway.com/template/{{RAILWAY_TEMPLATE_ID}}?referralCode={{RAILWAY_REFERRAL_CODE}}) | $5/mo Hobby tier handles thousands of sessions; `wss://` works out of the box. |
| **DigitalOcean** | [![Deploy to DigitalOcean](https://www.deploytodo.com/do-btn-blue.svg)](https://cloud.digitalocean.com/apps/new?repo=https://github.com/dvai-global/dvai-bridge/tree/main/rendezvous&refcode={{DIGITALOCEAN_REFERRAL_CODE}}) | $5/mo basic-xxs droplet; assigns a `*.ondigitalocean.app` URL. |

> **Note:** the buttons above include affiliate referral codes that
> earn the dvai-bridge maintainers a small commission. If you'd rather
> deploy without contributing, use the platform's UI directly without
> the `referralCode` / `refcode` query param. See
> [DEPLOYMENT.md](./DEPLOYMENT.md) for vendor-neutral instructions.

## Other platforms (self-host without referral)

[DEPLOYMENT.md](./DEPLOYMENT.md) covers Vercel, Netlify, Render, Fly.io,
Heroku, AWS App Runner, Google Cloud Run, and bare-VM Docker. None of
these have a referral program that pays us, so we don't headline them
with a button — but they all work.

## Running locally

```bash
git clone https://github.com/dvai-global/dvai-bridge.git
cd dvai-bridge/rendezvous
npm install
npm run build
npm start
# → rendezvous server listening on :8080
```

In another terminal:

```bash
curl http://localhost:8080/health
# {"status":"ok","activeSessions":0,"uptimeSec":12,"version":"0.1.0"}
```

For development with auto-reload:

```bash
npm run dev
```

## Configuration

All via env vars. See [`.env.example`](./.env.example) for the full
list with comments. Minimum:

| Var | Default | Purpose |
|---|---|---|
| `PORT` | `8080` | bind port |
| `HOST` | `0.0.0.0` | bind interface |
| `RENDEZVOUS_URL` | `ws://localhost:8080` | public URL the server is reachable at; goes into QR payloads |
| `SESSION_TTL_SECONDS` | `60` | inactivity-cutoff for pairing sessions |
| `MAX_SESSIONS` | `10000` | hard cap on concurrent sessions |
| `ALLOWED_ORIGINS` | `*` | CORS allowlist (comma-separated) |

## Wire protocol

Two clients open a WebSocket to `/pair`. The first sends
`{type: "pair-source", ...}`; the server replies with a session ID and
a QR payload. The second client (target — typically a different
device that scans the QR) sends `{type: "pair-target", sessionId, ...}`.
The server then forwards `{type: "relay", ...}` frames between the two
peers until either disconnects or the session times out.

The server **never sees plaintext inference data**. Both peers do
their own AEAD encryption with a shared secret derived from an X25519
exchange that the server only relays public keys for.

Full message types: [`src/messages.ts`](./src/messages.ts).

## Resource floor

- 256 MB RAM is plenty for ~10k concurrent sessions.
- Single vCPU is fine — relay traffic is small (LLM token streams are
  KB/s, not MB/s).
- Memory grows linearly with active sessions; pruned on TTL expiry.
- Stateless beyond the in-memory `Map<sessionId, Session>`. Restart =
  all sessions die; clients re-pair.

For >10k concurrent sessions or multi-instance horizontal scaling,
a Redis-backed session store is on the v3.2+ roadmap. Until then,
vertically scaling a single instance is the simplest path.

## Security

- The server **does not authenticate** clients. Any device that can
  reach the public URL can request a pairing session. Rate-limiting
  (sessions/IP/min) is the only abuse defense — see `MAX_SESSIONS`
  and the per-IP throttle documented in
  [DEPLOYMENT.md](./DEPLOYMENT.md).
- The server **does not see plaintext** inference traffic. Both peers
  encrypt with a per-session key derived from X25519. The server only
  relays public keys + opaque AEAD-encrypted payloads.
- The server **does not store anything persistent**. Restarts wipe
  all session state. There is no log of what was inferred, where, or
  by whom.
- Run behind your platform's TLS termination (Railway, DO, Cloudflare,
  etc. all do this for you). Plain `ws://` should not be exposed
  publicly.

## License

Custom — same terms as the parent dvai-bridge repository.
See [`../LICENSE`](../LICENSE).
