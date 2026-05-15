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
| **DigitalOcean** | [![Deploy to DigitalOcean](https://www.deploytodo.com/do-btn-blue.svg)](https://cloud.digitalocean.com/apps/new?repo=https://github.com/dvai-global/dvai-bridge/tree/main/rendezvous&refcode={{DIGITALOCEAN_REFERRAL_CODE}}) | $5/mo basic-xxs |

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
App Runner, or any Linux VM with Docker. The platform-by-platform
walkthrough below covers every supported host. (The same content
ships in the repo at
[`rendezvous/DEPLOYMENT.md`](https://github.com/dvai-global/dvai-bridge/blob/main/rendezvous/DEPLOYMENT.md)
for people who land on the source first.)

### Fly.io

```bash
cd rendezvous
fly launch --copy-config --name dvai-bridge-rendezvous
# Edit fly.toml: set internal_port = 8080
fly deploy
fly status
# → URL is https://dvai-bridge-rendezvous.fly.dev
```

Set `RENDEZVOUS_URL=wss://dvai-bridge-rendezvous.fly.dev` via
`fly secrets set`.

### Render.com

1. Connect your GitHub repo at <https://render.com/>.
2. Create a new Web Service.
3. Root directory: `rendezvous`.
4. Build: `npm install && npm run build`.
5. Start: `npm start`.
6. Add env vars per `.env.example`.
7. Render assigns a `*.onrender.com` URL.

### Vercel / Netlify

These platforms are optimised for static + serverless functions, and
WebSockets aren't a great fit for their request-per-invocation model.
Possible via their long-running compute tiers but not recommended —
the Railway / DO / Fly / Render path is simpler.

If you must:
- **Vercel:** deploy as a Node serverless function with
  `export const maxDuration = 300` and use the platform's WebSocket
  support (currently in preview).
- **Netlify:** similar caveats; use Netlify Functions with the
  `serverless-ws` adapter.

For most teams the higher-quality WebSocket support on Railway / DO /
Fly / Render is worth the small monthly cost.

### AWS

#### App Runner

```bash
# Create an ECR repo, push the Docker image, then:
aws apprunner create-service \
  --service-name dvai-bridge-rendezvous \
  --source-configuration ImageRepository={...}
```

App Runner does WebSockets. It's pricier than Railway / DO at this
workload size (typically $25-50/mo vs $5/mo).

#### ECS Fargate

For shops already on AWS infra. Build the Docker image, push to ECR,
launch a Fargate service behind an ALB. WebSocket-aware target group.
Same code, same env vars; just more YAML.

### Google Cloud Run

```bash
gcloud run deploy dvai-bridge-rendezvous \
  --source . \
  --port 8080 \
  --allow-unauthenticated \
  --region us-central1
```

Cloud Run supports WebSockets up to 60-minute connections, which is
plenty for a 60-second pairing TTL.

### Bare VM with Docker

```bash
# On any Linux box with Docker installed:
docker build -t dvai-bridge-rendezvous .
docker run -d \
  --name rendezvous \
  --restart unless-stopped \
  -p 8080:8080 \
  -e RENDEZVOUS_URL=wss://yourdomain.com \
  -e ALLOWED_ORIGINS=https://yourapp.com \
  dvai-bridge-rendezvous
```

Front it with Caddy / Nginx / Traefik for TLS termination. Sample
Caddyfile:

```
yourdomain.com {
    reverse_proxy localhost:8080
}
```

Caddy auto-provisions a Let's Encrypt cert. Done.

### Kubernetes

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dvai-bridge-rendezvous
spec:
  replicas: 1   # see "scaling beyond one instance" below
  selector:
    matchLabels: { app: rendezvous }
  template:
    metadata:
      labels: { app: rendezvous }
    spec:
      containers:
        - name: rendezvous
          image: ghcr.io/yourname/dvai-bridge-rendezvous:0.1.0
          ports: [{containerPort: 8080}]
          envFrom: [{configMapRef: {name: rendezvous-env}}]
          livenessProbe:
            httpGet: {path: /health, port: 8080}
            initialDelaySeconds: 10
            periodSeconds: 30
          readinessProbe:
            httpGet: {path: /health, port: 8080}
            periodSeconds: 10
```

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

## Scaling beyond one instance

The current server stores sessions in a per-process `Map`. A second
instance won't see the first's sessions — pairing will fail
~50% of the time as the source and target hit different replicas.

Workarounds:

1. **Sticky sessions** — configure the platform's load balancer to
   pin a client to the same instance for the lifetime of the WS
   connection. Most LBs (HAProxy, ALB, Nginx, Cloudflare) support
   this. Works fine until ~10k concurrent sessions per instance.
2. **Vertical scaling** — bump the single instance's RAM / CPU. The
   server is small enough that one $20/mo instance comfortably
   handles ~50k concurrent sessions.
3. **Redis-backed session store** — on the v3.2+ roadmap. Replace
   the in-memory `SessionStore` with one that reads/writes to
   Redis, then run as many instances as you want behind a
   non-sticky LB.

For most apps in v3.0's lifetime, vertical scaling + sticky LB is
plenty.

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
- **WebSocket close 1006 at the client** → the platform's
  idle-connection timeout is shorter than your
  `SESSION_TTL_SECONDS`. Tune the platform side or rely on the
  library's automatic ping frames (sent every 25 seconds once a
  session is active).
- **Pairing fails consistently across networks** → confirm
  `RENDEZVOUS_URL` env var matches the public URL the server is
  reachable at. If wrong, the QR payload encodes a URL the target
  can't connect to.
- **`/pair` returns 404** → the `@fastify/websocket` plugin didn't
  load. Check that `npm install` completed cleanly; the plugin is a
  hard dep.

## Updating the server

Rendezvous server versions follow the parent dvai-bridge repo's tags
(`v3.0.0`, `v3.0.1`, etc.). Updates are backwards-compatible within a
major version. To update on a managed platform: redeploy from `main`
(or the latest tag). To update from Docker: `docker pull` the new
image tag and `docker restart`.

The wire protocol (`rendezvous/src/messages.ts`) is versioned via the
`v: 1` field in QR payloads. Future protocol changes will bump the
version and accept both old and new for a deprecation window.

## Contributing changes to the server

The server lives at [`rendezvous/`](https://github.com/dvai-global/dvai-bridge/tree/main/rendezvous)
in the dvai-bridge monorepo. PRs welcome — see
[CONTRIBUTING.md](https://github.com/dvai-global/dvai-bridge/blob/main/CONTRIBUTING.md).
The server has its own test suite (`npm test` from `rendezvous/`)
and is deliberately small enough to read end-to-end in a sitting.
