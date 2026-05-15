# Self-hosting the rendezvous server

The one-click buttons in [README.md](./README.md) are the fastest path
for the two platforms with referral programs we benefit from (Railway
and DigitalOcean). This document covers everything else: vendor-neutral
deploys, custom domains, scaling, and security hardening.

## Prerequisites

- The `rendezvous/` directory of the dvai-bridge repository (`git clone https://github.com/dvai-global/dvai-bridge.git`).
- Or the same directory copied to a standalone repo (it has no
  workspace-package dependencies; it's fully self-contained).

## Platform-by-platform

### Railway (with referral)

Click the deploy button in the README, or:

```bash
# Manually:
railway login
railway init
railway up
railway domain
# → assigns a *.up.railway.app URL
```

Set `RENDEZVOUS_URL=wss://<your-app>.up.railway.app` in the Railway
dashboard's Variables tab, then redeploy.

### DigitalOcean App Platform (with referral)

Click the deploy button in the README, or:

```bash
doctl apps create --spec app.yaml
doctl apps list
```

Set `RENDEZVOUS_URL=wss://<your-app>.ondigitalocean.app` after the
first deploy, then `doctl apps update`.

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

1. Connect your GitHub repo at https://render.com/.
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
- Vercel: deploy as a Node serverless function with `export const maxDuration = 300` and use the platform's WebSocket support (currently in preview).
- Netlify: similar caveats; use Netlify Functions with the `serverless-ws` adapter.

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

After the platform assigns a default URL (`*.up.railway.app`, etc.),
attach your own:

1. **Add the domain** in the platform's dashboard — most issue you a
   CNAME target.
2. **Set the DNS CNAME** at your registrar:
   ```
   rendezvous.yourapp.com  CNAME  <platform-cname-target>
   ```
3. **Wait for cert provisioning** — most platforms auto-issue a
   Let's Encrypt cert; usually ready in 1-15 minutes.
4. **Update `RENDEZVOUS_URL`** in your env vars to
   `wss://rendezvous.yourapp.com`. Redeploy.
5. **Verify**:
   ```bash
   curl https://rendezvous.yourapp.com/health
   ```

## Scaling beyond one instance

The current server stores sessions in a per-process `Map`. A second
instance won't see the first's sessions — pairing will fail
~50% of the time as the source and target hit different replicas.

Workarounds:

1. **Sticky sessions** — configure the platform's load balancer to
   pin a client to the same instance for the lifetime of the WS
   connection. Most LBs (HAProxy, ALB, Nginx, Cloudflare) support this.
   Works fine until ~10k concurrent sessions per instance.

2. **Vertical scaling** — bump the single instance's RAM / CPU. The
   server is small enough that one $20/mo instance comfortably handles
   ~50k concurrent sessions.

3. **Redis-backed session store** — on the v3.2+ roadmap. Replace
   the in-memory `SessionStore` with one that reads/writes to Redis,
   then run as many instances as you want behind a non-sticky LB.

For most apps in v3.0's lifetime, vertical scaling + sticky LB is
plenty.

## Security checklist

- [ ] **TLS termination** is in place (`wss://` not `ws://`). Most
      managed platforms do this for you. For bare VMs, use Caddy / Nginx
      with auto-provisioned Let's Encrypt.
- [ ] **`ALLOWED_ORIGINS`** is set to your app's domain(s), not `*`.
- [ ] **`MAX_SESSIONS`** is sized for your real load with headroom.
- [ ] **Rate limiting at the platform layer** — Cloudflare WAF, AWS
      WAF, or your reverse proxy's rate-limit module. Pin to ~10
      sessions/IP/min.
- [ ] **Server logs** don't capture sensitive data (the server only
      sees opaque AEAD-encrypted payloads, but log noise can still
      leak metadata like deviceIds — set `LOG_LEVEL=warn` in production).
- [ ] **Health-check exposes minimal info**. Default `/health` returns
      counts only; safe to expose. `/metrics` is more verbose; gate it
      behind `METRICS_ENABLED=1` only when you're ready to scrape it.
- [ ] **Restart policy** is set to "always" / "on failure" so the
      server self-heals from crashes. The Dockerfile, `railway.json`,
      and `app.yaml` all include this.

## Troubleshooting

- **"WebSocket close 1006"** at the client → the platform's idle-connection
  timeout is shorter than your `SESSION_TTL_SECONDS`. Tune the platform
  side or add periodic `ping` frames at the client (the wire protocol
  supports them; library does this automatically).
- **"Pairing fails consistently across networks"** → confirm
  `RENDEZVOUS_URL` env var matches the public URL the server is reachable
  at. If wrong, the QR payload encodes a URL the target can't connect to.
- **"`/pair` returns 404"** → the `@fastify/websocket` plugin didn't load.
  Check that `npm install` completed cleanly; the plugin is a hard dep.
- **"Health endpoint says `ok` but clients can't connect"** → check
  `ALLOWED_ORIGINS`. If your app's WebSocket call has an `Origin` header
  that doesn't match, the server closes the connection.

## Updating the server

Rendezvous server versions follow the parent dvai-bridge repo's tags
(`v3.0.0`, `v3.0.1`, etc.). Updates are backwards-compatible within a
major version. To update on a managed platform: redeploy from `main`
(or the latest tag). To update from Docker: `docker pull` the new
image tag and `docker restart`.

The wire protocol (`src/messages.ts`) is versioned via the `v: 1`
field in QR payloads. Future protocol changes will bump the version
and accept both old and new for a deprecation window.
