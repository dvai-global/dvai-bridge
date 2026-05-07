# Self-hosting the rendezvous server

dvai-bridge's [distributed-inference](./distributed-inference) feature
has two paths for finding peer devices to offload to:

1. **LAN**: zero setup. Devices on the same Wi-Fi discover each other
   via mDNS / Bonjour. No server needed.
2. **Internet**: requires a small WebSocket relay (the **rendezvous
   server**) that you self-host. Two devices on different networks
   pair via QR scan, then exchange encrypted inference traffic
   through the relay.

The rendezvous server is **optional**. If you don't deploy one and
don't set `rendezvousUrl` in your config, the internet path is
disabled — your app's offload behaviour falls back to LAN-only,
which is the right choice for many use-cases.

This page covers when to deploy a rendezvous server, the one-click
deploy flow, and what you're committing to operationally.

## Should you deploy one?

**Yes**, if your app users will routinely:

- Have a phone on cellular and a laptop at home, and want the laptop
  to do the heavy lifting for the phone's inference requests.
- Use multiple devices on different networks belonging to the same
  user (BYOD enterprise scenarios, family-account apps).
- Demonstrate your app at a conference where the show's Wi-Fi blocks
  mDNS and the user's devices need to pair via QR + cellular.

**No**, if:

- Your app users only ever run inference on one device at a time.
- Your users are always on the same network as their other devices
  (LAN mDNS already covers this).
- You're not OK with operating a small (cheap, but real) piece of
  infrastructure.

## Architecture summary

The server is a thin WebSocket relay:

- Two devices connect; one displays a QR, the other scans it.
- Server mediates X25519 key exchange (just relays public keys).
- Devices derive a shared secret independently; AEAD-encrypt all
  subsequent traffic.
- Server forwards opaque encrypted payloads back and forth.
- **Server never sees plaintext inference data** — it can't, even
  if compromised.
- Stateless beyond per-session memory; restarts wipe sessions.

Resource footprint is tiny — a $5/mo box handles thousands of
concurrent pairings.

## One-click deploy

Pick whichever platform you prefer; both have referral programs that
help fund dvai-bridge maintenance:

| Platform | Click to deploy | Cost (typical) |
|---|---|---|
| **Railway** | [![Deploy on Railway](https://railway.app/button.svg)](https://railway.com/template/{{RAILWAY_TEMPLATE_ID}}?referralCode={{RAILWAY_REFERRAL_CODE}}) | $5/mo Hobby |
| **DigitalOcean** | [![Deploy to DigitalOcean](https://www.deploytodo.com/do-btn-blue.svg)](https://cloud.digitalocean.com/apps/new?repo=https://github.com/Westenets/dvai-bridge/tree/main/rendezvous&refcode={{DIGITALOCEAN_REFERRAL_CODE}}) | $5/mo basic-xxs |

After deploy:

1. Note the URL the platform assigns (`*.up.railway.app` or
   `*.ondigitalocean.app`).
2. Set `RENDEZVOUS_URL=wss://<your-url>` as an env var in the platform
   dashboard. Redeploy.
3. Configure your dvai-bridge app to point at it:

   ```ts
   const dvai = new DVAI({
     backend: "auto",
     offload: {
       enabled: true,
       rendezvousUrl: "wss://your-rendezvous.up.railway.app",
       // ...
     },
   });
   ```

That's it. Internet pairing now works.

## Other platforms

Railway and DigitalOcean are headlined because they pay us a referral
commission, but the server runs equally well on Fly.io, Render,
Cloudflare Workers (with WebSocket support), Google Cloud Run, AWS
App Runner, or any Linux VM with Docker.

For platform-by-platform instructions including Vercel, Netlify, AWS,
GCP, Kubernetes, and bare-VM Docker, see the
[`rendezvous/DEPLOYMENT.md`](https://github.com/Westenets/dvai-bridge/blob/main/rendezvous/DEPLOYMENT.md)
in the repo.

## Custom domain

After your platform assigns a default URL, you'll probably want to
attach your own:

1. **In the platform dashboard:** add the custom domain. The platform
   shows you a CNAME target.
2. **At your DNS registrar:** create a CNAME record pointing
   `rendezvous.yourapp.com` at the platform's CNAME target.
3. **Wait** ~5-15 min for the platform to provision a TLS cert
   (Let's Encrypt; auto on every major platform).
4. **Update `RENDEZVOUS_URL`** in your env vars to
   `wss://rendezvous.yourapp.com`. Redeploy.
5. **Update the dvai-bridge config in your app(s)** to use the new URL.

## Operational checklist

- [ ] **TLS** is on (`wss://`, not `ws://`). Every managed platform
      handles this automatically.
- [ ] **Custom domain** with auto-renewing cert.
- [ ] **`ALLOWED_ORIGINS`** env var locks down to your app's
      origin(s). Default `*` is fine for early testing; not OK in
      production.
- [ ] **`MAX_SESSIONS`** sized for your real load (default 10000;
      256 MB RAM handles this).
- [ ] **Monitoring** — at minimum, alert on the `/health` endpoint
      returning non-200. Most platforms do this for you.
- [ ] **Restart-on-crash** — `Dockerfile`, `railway.json`, and
      `app.yaml` all set this; verify in your platform's settings.
- [ ] **Decide on log retention** — server logs are minimal but
      include device IDs. Choose a retention policy that matches
      your privacy promises to users.

## What about hosting a rendezvous server we run for you?

We don't. dvai-bridge is a library, not a service. Operating a
rendezvous server for the world would (a) make us a man-in-the-middle
nobody asked for, (b) create an abuse vector we'd have to police, and
(c) make our infrastructure part of every consumer's uptime story
forever. The whole point of the library is that you own the inference
stack — that includes the optional helper server.

The server code is small (a few hundred lines), well-tested, and
deploys in under 5 minutes. Do it once and forget it.

## Troubleshooting

- **Pairing connects then immediately drops** → Platform's
  idle-WebSocket timeout is shorter than `SESSION_TTL_SECONDS`.
  Tune the platform side or shorten `SESSION_TTL_SECONDS`. The
  client library sends periodic pings automatically once a session
  is active, which most platforms accept as activity.
- **`/health` works but `wss://` connection fails** → Check your
  platform routes WebSocket upgrades correctly. Most do; some require
  an explicit "WebSockets enabled" toggle.
- **CORS error in browser apps** → Set `ALLOWED_ORIGINS` to include
  the origin your browser app loads from.
- **Server occasionally crashes under load** → Check memory.
  `MAX_SESSIONS` defaults to 10k assuming 256 MB; if you've sized
  smaller, lower the cap.

## Contributing changes to the server

The server lives at [`rendezvous/`](https://github.com/Westenets/dvai-bridge/tree/main/rendezvous)
in the dvai-bridge monorepo. PRs welcome — see
[CONTRIBUTING.md](https://github.com/Westenets/dvai-bridge/blob/main/CONTRIBUTING.md).
The server has its own test suite (`npm test` from `rendezvous/`)
and is deliberately small enough to read end-to-end in a sitting.
