/**
 * Phase 4 — DVAI Hub Node sidecar entry point.
 *
 * Spawned as a child process by the Tauri Rust shell. Speaks newline-
 * delimited JSON-RPC over stdin/stdout. Owns the long-lived `PeerMode`
 * instance, the `DVAI` server from `@dvai-bridge/core`, and the bridge
 * between LAN-discovery / pairing-request events and the Tauri shell
 * (which forwards them to the dashboard frontend).
 *
 * Stdio protocol:
 *   request:      { "id": "<uuid>", "method": "<name>", "params": { ... } }
 *   response:     { "id": "<uuid>", "result": { ... } | "error": {...} }
 *   notification: { "method": "<name>", "params": { ... } }
 *
 * The shell maps each command (`get_status`, `get_pairings`, ...) to a
 * Tauri `invoke()` channel. Notifications (`pairing-request`,
 * `offload-served`) are emitted as Tauri events for the frontend to
 * subscribe to.
 */

import { createInterface } from "node:readline";
import { homedir } from "node:os";
import * as path from "node:path";

import { PeerMode } from "./PeerMode.js";
import { OllamaAdapter } from "./adapters/OllamaAdapter.js";
import type {
  EngineBridgeAdapter,
  PeerModeOptions,
} from "./PeerMode.js";
import type { OffloadAudit, PairingRequest } from "./MultiTenantPairing.js";

/* -------------------------------------------------------------------------- */
/* Wire types                                                                 */
/* -------------------------------------------------------------------------- */

interface RpcRequest {
  id: string;
  method: string;
  params?: Record<string, unknown>;
}

interface RpcResponse {
  id: string;
  result?: unknown;
  error?: { code: number; message: string };
}

interface RpcNotification {
  method: string;
  params: unknown;
}

/* -------------------------------------------------------------------------- */
/* Config                                                                     */
/* -------------------------------------------------------------------------- */

const STORE_DIR = process.env.DVAI_HUB_STORE_DIR
  ?? path.join(homedir(), ".dvai-hub");

/**
 * Per-pairing-request approval state. The Rust shell forwards the
 * `pairing-request` notification to the frontend, which surfaces a
 * modal; the frontend's response comes back as `respond_to_pairing`.
 */
const pendingPairings = new Map<string, (approved: boolean) => void>();

/** Queue of audit entries the shell hasn't fetched yet. (Best-effort.) */
let pendingAudit: OffloadAudit[] = [];

/* -------------------------------------------------------------------------- */
/* Stdio                                                                      */
/* -------------------------------------------------------------------------- */

function emit(message: RpcResponse | RpcNotification): void {
  process.stdout.write(JSON.stringify(message) + "\n");
}

function notify(method: string, params: unknown): void {
  emit({ method, params });
}

function respond(id: string, result: unknown): void {
  emit({ id, result });
}

function respondError(id: string, code: number, message: string): void {
  emit({ id, error: { code, message } });
}

/* -------------------------------------------------------------------------- */
/* Bring up PeerMode                                                          */
/* -------------------------------------------------------------------------- */

const adapters: EngineBridgeAdapter[] = [new OllamaAdapter()];

const peerOptions: PeerModeOptions = {
  storeDir: STORE_DIR,
  externalEnginesEnabled: true,
  engineAdapters: adapters,
  onPairingRequest: (request) => awaitPairingApproval(request),
  onOffloadServed: (audit) => {
    pendingAudit.push(audit);
    notify("offload-served", audit);
  },
  preferBetterQuant: false,
};

const peer = new PeerMode(peerOptions);

function awaitPairingApproval(request: PairingRequest): Promise<boolean> {
  return new Promise<boolean>((resolve) => {
    const requestId = `${request.appId}::${request.peerDeviceId}::${Date.now()}`;
    pendingPairings.set(requestId, resolve);
    notify("pairing-request", { requestId, request });
    // 5-minute fallback — never leak a Promise.
    setTimeout(() => {
      const fn = pendingPairings.get(requestId);
      if (fn) {
        pendingPairings.delete(requestId);
        fn(false);
      }
    }, 5 * 60 * 1000);
  });
}

/* -------------------------------------------------------------------------- */
/* Method dispatch                                                            */
/* -------------------------------------------------------------------------- */

const handlers: Record<string, (params: Record<string, unknown>) => Promise<unknown>> = {
  start: async () => {
    const status = await peer.start();
    return status;
  },
  stop: async () => {
    await peer.stop();
    return { ok: true };
  },
  get_status: async () => peer.getStatus(),
  get_pairings: async () => peer.listAllPairings(),
  revoke_pairing: async (params) => {
    const appId = String(params.appId ?? "");
    const peerDeviceId = String(params.peerDeviceId ?? "");
    if (!appId || !peerDeviceId) throw new Error("appId + peerDeviceId required");
    await peer.revokePairing(appId, peerDeviceId);
    return { ok: true };
  },
  get_engines: async () => peer.getDetectedEngines(),
  set_engine_enabled: async (_params) => {
    // Wired in Task 7d — for v3.1 rc1 this only invalidates the cache so
    // a future detect() takes effect. The full toggle plumbs in Task 9.
    await peer.invalidateEngineCache();
    return { ok: true };
  },
  invalidate_engine_cache: async (params) => {
    const name = typeof params.name === "string" ? params.name : undefined;
    await peer.invalidateEngineCache(name);
    return { ok: true };
  },
  respond_to_pairing: async (params) => {
    const id = String(params.requestId ?? "");
    const approved = Boolean(params.approved);
    const fn = pendingPairings.get(id);
    if (!fn) {
      // Idempotent — double-respond is a no-op
      return { ok: false, reason: "no_such_request" };
    }
    pendingPairings.delete(id);
    fn(approved);
    return { ok: true };
  },
  get_audit_log: async (params) => {
    const appId = String(params.appId ?? "");
    const limit = typeof params.limit === "number" ? params.limit : undefined;
    if (!appId) throw new Error("appId required");
    return peer.getAppAudit(appId, limit);
  },
  shutdown: async () => {
    await peer.stop();
    setImmediate(() => process.exit(0));
    return { ok: true };
  },
};

async function dispatch(req: RpcRequest): Promise<void> {
  const handler = handlers[req.method];
  if (!handler) {
    respondError(req.id, -32601, `unknown method "${req.method}"`);
    return;
  }
  try {
    const result = await handler(req.params ?? {});
    respond(req.id, result);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    respondError(req.id, -32000, message);
  }
}

/* -------------------------------------------------------------------------- */
/* Read loop                                                                  */
/* -------------------------------------------------------------------------- */

const rl = createInterface({
  input: process.stdin,
  crlfDelay: Infinity,
});

rl.on("line", (line) => {
  const trimmed = line.trim();
  if (!trimmed) return;
  let parsed: RpcRequest;
  try {
    parsed = JSON.parse(trimmed) as RpcRequest;
  } catch {
    process.stderr.write(`[server] failed to parse line: ${trimmed}\n`);
    return;
  }
  void dispatch(parsed);
});

rl.on("close", () => {
  // Stdin closed — Rust shell is shutting us down. Stop peer-mode cleanly.
  void peer.stop().finally(() => process.exit(0));
});

// Boot: announce we're alive so the shell can mark "ready".
notify("ready", { version: process.env.npm_package_version ?? "3.1.0", pid: process.pid });

// Drain pendingAudit periodically (keeps the array bounded; the array
// is also pushed via notifications so the frontend has live data).
setInterval(() => {
  if (pendingAudit.length > 1024) {
    pendingAudit = pendingAudit.slice(-512);
  }
}, 30_000).unref();
