# 2-device E2E testing for distributed inference (v3.0+)

This page is the canonical procedure for verifying the v3.0
distributed-inference path end-to-end across two real devices. The
unit tests in each SDK (capability cache, mDNS round-trip, HMAC
handshake, offload-decision) cover the substrate; this doc covers
the *integration* — does a request actually offload from a weak
device to a strong device, and does the structured error fire
when no peer is reachable?

Use this when:
- Verifying a release-candidate (v3.0.0-rc → v3.0.0 final).
- Reproducing an issue a consumer reports.
- Smoke-testing after a substantive change to discovery, pairing, or
  offload code.

## What you need

- **Two devices**, owned by you, on the same Wi-Fi to start.
  Recommended pairing: a Windows laptop + a Mac (the project's
  reference rig); or a phone + a laptop; or two laptops.
- The dvai-bridge repository checked out on each.
- A model both devices can load. The 1B reference (`Llama-3.2-1B-Instruct-Q4_K_M`)
  is the cheapest baseline; for dramatic offload demonstrations, use
  a 3B+ model the weak device technically can run but at low tok/s.
- (For the internet-path test only) A deployed rendezvous server.
  See [`docs/guide/self-hosting-rendezvous.md`](../guide/self-hosting-rendezvous.md).

## Test 1 — LAN offload (no rendezvous server needed)

### 1.1 Setup

On each device, install + configure the same example app.
The repo's reference example is `examples/web-react/` (Node-side
inference, easiest to run on both Windows and Mac):

```bash
# On both devices:
git clone https://github.com/Westenets/dvai-bridge.git
cd dvai-bridge
pnpm install --ignore-scripts
pnpm --filter @dvai-bridge/core run build
pnpm --filter web-react run dev
```

Configure each instance with `offload.enabled` and the same model:

```ts
// In examples/web-react/src/App.tsx (or your test app):
const dvai = new DVAI({
  backend: "transformers",
  transformersModelId: "onnx-community/Llama-3.2-1B-Instruct-ONNX",
  offload: {
    enabled: true,
    discoverLAN: true,
    minLocalCapability: 5,  // low so the weak device offloads
    onPairingRequest: async (peer) => {
      // Surface a UI prompt; for testing, auto-approve:
      console.log(`Pairing request from ${peer.deviceName} (${peer.deviceId})`);
      return true;
    },
    onOffload: (peer) => {
      console.log(`OFFLOADED to ${peer.deviceName}`);
    },
  },
});
await dvai.initialize();
```

Browsers can't speak mDNS — for the LAN test, run the example with
`@dvai-bridge/core` in **Node** on both devices (or use the
`react-native-app` / `flutter-app` / native iOS / native Android
examples that DO have mDNS).

### 1.2 Discovery

On the strong device (Mac or Linux), keep dvai-bridge running.
On the weak device (or another instance), start dvai-bridge with
`offload.enabled: true`. Within ~30 seconds, the weak device should
discover the strong device:

```bash
# On the weak device:
curl http://127.0.0.1:38883/v1/dvai/peers
# → {"peers": [{"deviceId": "...", "deviceName": "...", "baseUrl": "http://...", ...}]}
```

If the peer list is empty after 30s, see "Troubleshooting" below.

### 1.3 Pairing

Trigger the pairing handshake by making any chat completion request
through the weak device. The first request triggers
`onPairingRequest` on the strong device's side:

```bash
# On the weak device:
curl -X POST http://127.0.0.1:38883/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"Llama-3.2-1B","messages":[{"role":"user","content":"Hello"}]}'
```

On the strong device, the `onPairingRequest` callback fires; in your
test app it auto-approves. From this point on, the weak → strong
pairing is established (HMAC handshake; cached for 30 days).

### 1.4 Offload verification

Send another chat completion via the weak device. It should:

1. Compute or recall its local capability (e.g. 3 tok/s for 3B model).
2. See that 3 < `minLocalCapability` (5).
3. See the strong peer's reported capability is higher.
4. Proxy the request to the strong device's baseUrl.
5. Stream the response back through the weak device's local server.

The consumer's chat client (LangChain, OpenAI SDK, etc.) sees a
normal SSE-streamed response — same shape as if it had run locally.

To verify offload actually happened:
- Check the weak device's console for `"OFFLOADED to <peer name>"`.
- Check the strong device's logs — it received an HTTP request with
  `X-DVAI-Forwarded: 1` header.
- Send a request with `X-DVAI-Offload: never` and confirm the local
  device runs it (check timing — should be slower than the offload
  case if the weak device is genuinely weak).

### 1.5 Network partition test

While a streaming response is in flight, take the strong device
offline (disable Wi-Fi briefly). The weak device should:

- Surface a stream-interrupted error to the OpenAI client.
- NOT silently retry (per spec; consumer chooses retry policy).

## Test 2 — `no_capable_device` error

### 2.1 Setup

Configure the weak device with `minLocalCapability` higher than its
local score AND no other peers reachable:

```ts
const dvai = new DVAI({
  backend: "transformers",
  transformersModelId: "onnx-community/Llama-3.2-1B-Instruct-ONNX",
  offload: {
    enabled: true,
    discoverLAN: true,
    minLocalCapability: 100,  // unreachable on this device
  },
});
```

### 2.2 Request

```bash
curl -i -X POST http://127.0.0.1:38883/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'X-DVAI-Offload: require' \
  -d '{"model":"Llama-3.2-1B","messages":[{"role":"user","content":"Hello"}]}'
```

### 2.3 Expected response

HTTP 503 + `Retry-After: 30` + body:

```json
{
  "error": {
    "type": "no_capable_device",
    "code": 503,
    "message": "No device with capability ≥ 100 tok/s for model ... was reachable.",
    "checked": [
      { "deviceId": "self", "capabilityScore": 4.2, "reason": "below threshold" }
    ],
    "localCapability": 4.2,
    "requiredAtLeast": 100,
    "rendezvousConfigured": false,
    "pairedRemotePeers": 0
  }
}
```

If this fires, the structured-error path works.

## Test 3 — Internet offload via rendezvous server

This requires a deployed rendezvous server. See
[`docs/guide/self-hosting-rendezvous.md`](../guide/self-hosting-rendezvous.md)
for the deploy flow. Use the smallest tier of Railway or DigitalOcean
for testing.

### 3.1 Setup

Both devices (one on Wi-Fi, one on cellular or different network):

```ts
const dvai = new DVAI({
  backend: "...",
  modelId: "...",
  offload: {
    enabled: true,
    discoverLAN: true,
    rendezvousUrl: "wss://your-rendezvous.up.railway.app",
    minLocalCapability: 5,
    onPairingRequest: async (peer) => true,  // auto-approve for test
  },
});
```

### 3.2 QR-pair handshake

The QR-pair flow lights up in the per-SDK integrations (Tasks 8a–8f).
Until those expose `dvai.startQrPairing()` + `dvai.completePairFromQrPayload(payload)`,
test the WebSocket-relay path manually using a small `wscat`-style
script that mimics the source + target roles.

A reference test harness lives at:
- `rendezvous/scripts/test-2-device-internet-offload.sh` (TODO — adds in v3.0 final)

### 3.3 Offload verification

Same as Test 1.4 but the `peer.via` field reads `"rendezvous"`
instead of `"mdns"` in the response from
`GET /v1/dvai/peers`.

## Test matrix

| Scenario | Devices | Expected outcome |
|---|---|---|
| LAN, both reachable, weak device above threshold | Win + Mac on same Wi-Fi | Local on weak device |
| LAN, both reachable, weak device below threshold | Same | Offload to Mac; SSE streams back |
| LAN, weak below threshold, peer unreachable | Same, Mac sleeping | `no_capable_device` 503 |
| LAN, `X-DVAI-Offload: never`, weak below threshold | Same | Local on weak (forced) |
| LAN, `X-DVAI-Offload: require`, no qualified peer | Same, Mac sleeping | `no_capable_device` 503 |
| Internet via rendezvous, both reachable, paired | Phone (cellular) + Mac (Wi-Fi) | Offload to Mac; SSE streams back |
| Internet, peer unreachable | Same, Mac sleeping | `no_capable_device` 503 + diagnostic notes peer unreachable |
| Mid-stream peer drop | Mac + Win, Mac drops Wi-Fi mid-response | Stream-interrupted error to OpenAI client |
| Pairing first contact | Fresh weak + fresh strong | `onPairingRequest` fires once on strong; auto-approve test approves |
| Pairing reuse | Same pair after first | No prompt; HMAC reuses cached key |
| Pairing expiry | Wait 31 days | Re-handshake required |

## Troubleshooting

**Peer list stays empty after 30s on LAN:**
- mDNS may be blocked on the network (corporate Wi-Fi). Test on a
  home / hotspot Wi-Fi to confirm.
- Verify both devices are on the same subnet (`ipconfig` / `ifconfig`
  to compare the first three octets).
- Confirm the dvai-bridge instances are advertising — the embedded
  HTTP server's `/v1/dvai/health` endpoint should return `status: ok`.
- On Windows, Bonjour-for-Windows must be installed for the JS-side
  Node `multicast-dns` to resolve `*.local` names.

**Pairing prompt never fires:**
- Confirm `onPairingRequest` is wired in the OffloadConfig.
- Check the strong device's logs — the weak device's first request
  should hit `POST /v1/dvai/handshake` first.
- Verify `dvai.initialize()` (or `start()`) was called with
  `offload.enabled: true` BEFORE any chat completions hit the server.

**Offload happens but response never returns:**
- The peer's port might not be reachable (firewall). Try
  `curl <peer.baseUrl>/health` from the weak device.
- The model on the peer might still be downloading. First request
  after cold start can hang; subsequent requests are instant.

**`no_capable_device` returns when you expected an offload:**
- Verify the peer's `capability` map has an entry for the requested
  model. Run `curl <peer.baseUrl>/v1/dvai/capability` to inspect.
- Run `await dvai.probeCapability()` on the peer to populate the
  capability cache.

## Reporting issues

When filing a v3.0 bug, please include:
1. Output of `GET /v1/dvai/peers` from the weak device.
2. Output of `GET /v1/dvai/capability` from each device.
3. Network topology (same Wi-Fi? different subnets? captive portal?
   corporate firewall?).
4. The full chain of events from `dvai.initialize()` to the failed
   request (with `console.log` instrumentation around the offload
   callbacks).

File at <https://github.com/Westenets/dvai-bridge/issues> with
`[v3.0]` in the title.
