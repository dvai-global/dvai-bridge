/**
 * Phase 4 v3.1 wire-protocol smoke test.
 *
 *   1. Handshake with appId → expect pairingKey echoed back
 *   2. Verified identity request (correct HMAC) → 200 + audit logs real appId
 *   3. Rejected identity (bad HMAC) → 401
 *   4. Backwards-compat anonymous (no identity headers) → 200, audit logs "anonymous"
 *   5. preferBetterQuant=1 substitution path → 200 substituted (run separately under
 *      `DVAI_HUB_PREFER_BETTER_QUANT=1` Hub start)
 *
 * Run after `pnpm build:peer-mode`:
 *   node dist/scripts/smoke-identity.js
 */

import { composeSignedMessage, signHmac } from "@dvai-bridge/core";

const HUB = process.env.DVAI_HUB_URL ?? "http://127.0.0.1:38883";
const APP_ID = `com.acme.smoke-${Date.now()}`;
const DEVICE_ID = `phone-smoke-${Date.now()}`;
const DEVICE_NAME = "Smoke Test Phone";

function ok(label: string): void {
  console.log(`  ✅ ${label}`);
}
function fail(label: string, detail?: string): void {
  console.log(`  ❌ ${label}`);
  if (detail) console.log(`     ${detail}`);
  process.exitCode = 1;
}

async function postJson(
  path: string,
  bodyJson: string,
  extraHeaders: Record<string, string> = {},
): Promise<{ status: number; text: string }> {
  const res = await fetch(`${HUB}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...extraHeaders },
    body: bodyJson,
  });
  const text = await res.text();
  return { status: res.status, text };
}

async function step(n: number, title: string, fn: () => Promise<void>): Promise<void> {
  console.log(`\n[${n}] ${title}`);
  try {
    await fn();
  } catch (err) {
    fail("threw", err instanceof Error ? err.message : String(err));
  }
}

async function main(): Promise<void> {
  console.log(`Hub: ${HUB}`);
  console.log(`appId: ${APP_ID}`);
  console.log(`peerDeviceId: ${DEVICE_ID}`);

  /* -------------------------------------------------------------------- */
  /* Step 1 — handshake; expect pairingKey echoed                          */
  /* -------------------------------------------------------------------- */
  let pairingKey = "";
  await step(1, "handshake → expect 200 + pairingKey echoed", async () => {
    const handshakeBody = JSON.stringify({
      peerDeviceId: DEVICE_ID,
      peerDeviceName: DEVICE_NAME,
      appId: APP_ID,
      via: "lan-handshake",
    });
    const { status, text } = await postJson("/v1/dvai/handshake", handshakeBody);
    if (status !== 200) {
      return fail("status", `expected 200 got ${status}; body=${text.slice(0, 200)}`);
    }
    let parsed: { paired?: boolean; pairingKey?: string; peerDeviceId?: string };
    try {
      parsed = JSON.parse(text);
    } catch {
      return fail("parse handshake response", text.slice(0, 200));
    }
    if (!parsed.paired) return fail("paired", `body=${text}`);
    if (typeof parsed.pairingKey !== "string" || parsed.pairingKey.length < 32) {
      return fail("pairingKey echoed", `pairingKey=${String(parsed.pairingKey)}`);
    }
    if (parsed.peerDeviceId !== DEVICE_ID) {
      return fail("peerDeviceId echoed", `got ${parsed.peerDeviceId}`);
    }
    pairingKey = parsed.pairingKey;
    ok(`pairingKey: ${pairingKey.slice(0, 12)}…`);
  });
  if (!pairingKey) {
    console.log("\nCannot continue without pairingKey. Aborting.");
    process.exit(1);
  }

  /* -------------------------------------------------------------------- */
  /* Step 2 — verified identity, correct HMAC                              */
  /* -------------------------------------------------------------------- */
  await step(2, "verified identity → expect 200 + audit logs real appId", async () => {
    const reqBodyJson = JSON.stringify({
      model: "qwen2.5-coder:1.5b",
      messages: [{ role: "user", content: "Output only: 7+1=" }],
      max_tokens: 8,
      stream: false,
    });
    const nonce = `nonce-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const message = await composeSignedMessage(
      nonce,
      "POST",
      "/v1/chat/completions",
      reqBodyJson,
    );
    const signature = await signHmac(pairingKey, message);

    const { status, text } = await postJson("/v1/chat/completions", reqBodyJson, {
      "X-DVAI-Peer-Device-Id": DEVICE_ID,
      "X-DVAI-App-Id": APP_ID,
      "X-DVAI-Nonce": nonce,
      "X-DVAI-Signature": signature,
    });
    if (status !== 200) {
      return fail("status", `expected 200 got ${status}; body=${text.slice(0, 200)}`);
    }
    let parsed: { choices?: Array<{ message?: { content?: string } }>; system_fingerprint?: string };
    try { parsed = JSON.parse(text); } catch { return fail("parse", text.slice(0, 200)); }
    const content = parsed?.choices?.[0]?.message?.content ?? "";
    if (!content) return fail("response body", `text=${text.slice(0, 200)}`);
    ok(`response: "${content.replace(/\n/g, "\\n")}" (engine: ${parsed.system_fingerprint ?? "n/a"})`);
  });

  /* -------------------------------------------------------------------- */
  /* Step 3 — rejected: bad signature                                      */
  /* -------------------------------------------------------------------- */
  await step(3, "rejected identity (bad HMAC) → expect 401", async () => {
    const reqBodyJson = JSON.stringify({
      model: "qwen2.5-coder:1.5b",
      messages: [{ role: "user", content: "hi" }],
      max_tokens: 3,
    });
    const { status, text } = await postJson("/v1/chat/completions", reqBodyJson, {
      "X-DVAI-Peer-Device-Id": DEVICE_ID,
      "X-DVAI-App-Id": APP_ID,
      "X-DVAI-Nonce": "x",
      "X-DVAI-Signature": "deadbeef".repeat(8),
    });
    if (status !== 401) {
      return fail("status", `expected 401 got ${status}; body=${text.slice(0, 200)}`);
    }
    let parsed: { error?: { type?: string; message?: string } };
    try { parsed = JSON.parse(text); } catch { return fail("parse", text.slice(0, 200)); }
    if (parsed.error?.type !== "unauthorized") {
      return fail("error.type", `got ${parsed.error?.type}`);
    }
    ok(`401 unauthorized: "${parsed.error?.message ?? ""}"`);
  });

  /* -------------------------------------------------------------------- */
  /* Step 4 — anonymous backwards-compat (no identity headers)             */
  /* -------------------------------------------------------------------- */
  await step(4, "anonymous backwards-compat (no headers) → expect 200, audit appId=anonymous", async () => {
    const reqBodyJson = JSON.stringify({
      model: "qwen2.5-coder:1.5b",
      messages: [{ role: "user", content: "Output only: 9+1=" }],
      max_tokens: 5,
    });
    const { status, text } = await postJson("/v1/chat/completions", reqBodyJson);
    if (status !== 200) {
      return fail("status", `expected 200 got ${status}; body=${text.slice(0, 200)}`);
    }
    ok("200 (anonymous served — backwards compat works)");
  });

  /* -------------------------------------------------------------------- */
  /* Step 5 — preferBetterQuant substitution                               */
  /* -------------------------------------------------------------------- */
  await step(5, "preferBetterQuant=1: Q4_K_M → expect 200 substituted", async () => {
    // Hub local has quant=null, LM Studio has quant=q8_0. Request asks
    // Q4_K_M. With preferBetterQuant=true, the policy substitutes the
    // best same-shape backend.
    const reqBodyJson = JSON.stringify({
      model: "Llama-3.2-1B-Instruct-Q4_K_M",
      messages: [{ role: "user", content: "Reply with: SUB" }],
      max_tokens: 5,
      stream: false,
    });
    const nonce = `nonce-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const message = await composeSignedMessage(
      nonce,
      "POST",
      "/v1/chat/completions",
      reqBodyJson,
    );
    const signature = await signHmac(pairingKey, message);
    const { status, text } = await postJson("/v1/chat/completions", reqBodyJson, {
      "X-DVAI-Peer-Device-Id": DEVICE_ID,
      "X-DVAI-App-Id": APP_ID,
      "X-DVAI-Nonce": nonce,
      "X-DVAI-Signature": signature,
    });
    if (status === 503) {
      return fail(
        "expected substitution to succeed, got 503",
        `body=${text.slice(0, 200)}\n→ Make sure Hub was started with DVAI_HUB_PREFER_BETTER_QUANT=1.`,
      );
    }
    if (status !== 200) {
      return fail("status", `expected 200 got ${status}; body=${text.slice(0, 200)}`);
    }
    let parsed: { model?: string };
    try { parsed = JSON.parse(text); } catch { return fail("parse", text.slice(0, 200)); }
    const respModel = parsed?.model ?? "(no model field)";
    ok(`200 substituted; response model=${respModel}`);
  });

  console.log("\nDone. Check audit logs for verified vs anonymous identity:");
  console.log(`  ~/.dvai-hub/apps/${APP_ID}/audit.log    (verified)`);
  console.log("  ~/.dvai-hub/apps/anonymous/audit.log   (backwards-compat path)");
}

main().catch((err: unknown) => {
  console.error(err);
  process.exit(1);
});
