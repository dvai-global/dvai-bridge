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

// IMPORTANT: redirect console.* to stderr BEFORE importing DVAI / any
// other dependency. The JSON-RPC protocol owns stdout exclusively;
// any stray `console.log()` from a dep would otherwise appear as a
// non-JSON line and the Rust shell would reject it. Progress
// callbacks from Transformers.js, DVAI's internal status logs, and
// node-llama-cpp's chatter all flow through console — so we hijack
// the global console early.
const _stderr = (level: string, ...args: unknown[]): void => {
  const formatted = args
    .map((a) => {
      if (typeof a === "string") return a;
      try {
        return JSON.stringify(a);
      } catch {
        return String(a);
      }
    })
    .join(" ");
  process.stderr.write(`[${level}] ${formatted}\n`);
};
console.log = (...args) => _stderr("log", ...args);
console.info = (...args) => _stderr("info", ...args);
console.warn = (...args) => _stderr("warn", ...args);
console.error = (...args) => _stderr("error", ...args);
console.debug = (...args) => _stderr("debug", ...args);
// Some libraries also call .dir / .table; route those too.
console.dir = ((value: unknown): void => _stderr("dir", value)) as typeof console.dir;
console.table = ((value: unknown): void => _stderr("table", value)) as typeof console.table;

import { DVAI } from "@dvai-bridge/core";
import { PeerMode } from "./PeerMode.js";
import { parseModelName } from "./ModelParser.js";
import { OllamaAdapter } from "./adapters/OllamaAdapter.js";
import { LMStudioAdapter } from "./adapters/LMStudioAdapter.js";
import { LlamaServerAdapter } from "./adapters/LlamaServerAdapter.js";
import { VLLMAdapter } from "./adapters/VLLMAdapter.js";
import { LlamafileAdapter } from "./adapters/LlamafileAdapter.js";
import type {
  DvaiPeerLike,
  DvaiServerLike,
  EngineBridgeAdapter,
  PeerModeOptions,
} from "./PeerMode.js";
import type {
  ChatRequest,
  StreamResponse,
} from "./EngineBridge.js";
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
 * Backend selection for the Hub's local DVAI server. Defaults to a
 * small ONNX Llama via Transformers.js — universal and CPU-runnable.
 * Override via DVAI_HUB_BACKEND + DVAI_HUB_MODEL env vars; advanced
 * deployments (native node-llama-cpp with a GGUF on disk) set
 * DVAI_HUB_BACKEND=native and DVAI_HUB_NATIVE_MODEL_PATH.
 */
const HUB_BACKEND = (process.env.DVAI_HUB_BACKEND ?? "transformers") as
  | "transformers"
  | "native"
  | "auto"
  | "webllm";
const HUB_TRANSFORMERS_MODEL =
  process.env.DVAI_HUB_TRANSFORMERS_MODEL
  ?? "onnx-community/Llama-3.2-1B-Instruct-ONNX";
const HUB_NATIVE_MODEL_PATH = process.env.DVAI_HUB_NATIVE_MODEL_PATH;
const HUB_PORT = process.env.DVAI_HUB_PORT
  ? Number(process.env.DVAI_HUB_PORT)
  : undefined;
const HUB_RENDEZVOUS = process.env.DVAI_HUB_RENDEZVOUS_URL;
const HUB_PREFER_BETTER_QUANT = process.env.DVAI_HUB_PREFER_BETTER_QUANT === "1";
const EXTERNAL_ENGINES_ENABLED = process.env.DVAI_HUB_EXTERNAL_ENGINES !== "0";
// Transformers.js device: defaults to "cpu" in Node (Hub host) because
// WebGPU isn't available outside the browser and the auto-fallback
// inside @huggingface/transformers throws on the missing execution
// provider. Override with DVAI_HUB_DEVICE if needed (e.g. "webgpu" via
// an experimental Node runtime, or "auto" once upstream stabilises).
const HUB_DEVICE = (process.env.DVAI_HUB_DEVICE ?? "cpu") as
  | "auto"
  | "cpu"
  | "webgpu";
// Quantization for Transformers.js. Default "q4" — small + fast on CPU.
const HUB_DTYPE = process.env.DVAI_HUB_DTYPE ?? "q4";

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

const adapters: EngineBridgeAdapter[] = [
  new OllamaAdapter(),
  new LMStudioAdapter(),
  new LlamaServerAdapter(),
  new VLLMAdapter(),
  new LlamafileAdapter(),
];

/* -------------------------------------------------------------------------- */
/* Helpers                                                                    */
/* -------------------------------------------------------------------------- */

const ANON_TENANT_ID = "anonymous";

/** AsyncIterable<Uint8Array> → ReadableStream<Uint8Array> for SSE pipe-through. */
function asyncIterableToReadableStream(
  iter: AsyncIterable<Uint8Array>,
): ReadableStream<Uint8Array> {
  return new ReadableStream<Uint8Array>({
    async start(controller) {
      try {
        for await (const chunk of iter) {
          controller.enqueue(chunk);
        }
        controller.close();
      } catch (err) {
        controller.error(err);
      }
    },
  });
}

/**
 * /v1/chat/completions interceptor for the Hub. Runs BEFORE DVAI's
 * default local-backend handler. Applies the substitution policy +
 * engine bridge:
 *
 *   1. Parse `body.model`. Fall through (return null) if absent.
 *   2. peer.routeRequest() → RoutingDecision.
 *   3. Refuse → 503 + structured error + audit-record.
 *   4. Same-engine === "builtin" → audit-record + return null (DVAI's
 *      default handler runs the local backend).
 *   5. External engine → call adapter.serveRequest with the engine's
 *      own model id, pipe streaming response if applicable, audit.
 *
 * Audit identity: plain HTTP requests aren't HMAC-signed (curl tests
 * don't carry the pairing key). When we add the v3.1 wire-protocol
 * extension that surfaces the requester's appId/peerDeviceId, this
 * function reads those from request headers; until then it logs as
 * "anonymous".
 */
async function chatCompletionInterceptor(
  body: ChatRequest & { model?: unknown },
): Promise<Response | null> {
  const requestedModel = typeof body.model === "string" ? body.model : "";
  if (!requestedModel) return null;

  const startTs = Date.now();
  const requested = parseModelName(requestedModel);
  const decision = await peer.routeRequest(requested);

  // Refuse path
  if (decision.kind === "refuse") {
    await peer.recordOffloadAudit({
      ts: new Date().toISOString(),
      appId: ANON_TENANT_ID,
      peerDeviceId: ANON_TENANT_ID,
      engine: "none",
      requestedModel,
      servedModel: "",
      outcome: "refuse",
      reason: decision.reason,
      durationMs: Date.now() - startTs,
    });
    return Response.json(
      {
        error: {
          type: "no_capable_device",
          code: 503,
          message: `No backend can serve "${requestedModel}". Reason: ${decision.reason}.`,
          ...(decision.detail ? { detail: decision.detail } : {}),
        },
      },
      { status: 503 },
    );
  }

  const backend = decision.backend;

  // Local-backend path — fall through to DVAI's default handler.
  if (backend.engine === "builtin") {
    await peer.recordOffloadAudit({
      ts: new Date().toISOString(),
      appId: ANON_TENANT_ID,
      peerDeviceId: ANON_TENANT_ID,
      engine: "builtin",
      requestedModel,
      servedModel: backend.engineModelId,
      outcome: decision.kind,
      ...(decision.kind === "substituted" ? { reason: decision.reason } : {}),
      durationMs: Date.now() - startTs,
    });
    return null;
  }

  // External-engine path
  const adapter = peer.findEngineAdapter(backend.engine);
  if (!adapter) {
    await peer.recordOffloadAudit({
      ts: new Date().toISOString(),
      appId: ANON_TENANT_ID,
      peerDeviceId: ANON_TENANT_ID,
      engine: backend.engine,
      requestedModel,
      servedModel: "",
      outcome: "refuse",
      reason: "engine_adapter_not_found",
      durationMs: Date.now() - startTs,
    });
    return Response.json(
      {
        error: {
          type: "engine_adapter_not_found",
          code: 503,
          message: `Adapter for engine "${backend.engine}" is not available.`,
        },
      },
      { status: 503 },
    );
  }

  // Forward the request, but rewrite `model` to the engine's own id
  // (Ollama tag, LM Studio path, etc.).
  const adapterRequest: ChatRequest = {
    ...(body as ChatRequest),
    model: backend.engineModelId,
  };
  const adapterResponse = await adapter.serveRequest(
    backend.descriptor,
    adapterRequest,
  );

  // Streaming response (engine returned an AsyncIterable).
  const isStream = (body.stream === true) && "body" in adapterResponse
    && typeof (adapterResponse.body as { [Symbol.asyncIterator]?: unknown })[Symbol.asyncIterator] === "function";

  await peer.recordOffloadAudit({
    ts: new Date().toISOString(),
    appId: ANON_TENANT_ID,
    peerDeviceId: ANON_TENANT_ID,
    engine: backend.engine,
    requestedModel,
    servedModel: backend.engineModelId,
    outcome: decision.kind,
    ...(decision.kind === "substituted" ? { reason: decision.reason } : {}),
    durationMs: Date.now() - startTs,
  });

  const headers = { ...adapterResponse.headers };
  if (isStream) {
    const stream = asyncIterableToReadableStream(
      (adapterResponse as StreamResponse).body,
    );
    headers["Content-Type"] = headers["Content-Type"] ?? "text/event-stream";
    return new Response(stream, {
      status: adapterResponse.status,
      headers,
    });
  }
  return Response.json(adapterResponse.body, {
    status: adapterResponse.status,
    headers,
  });
}

/**
 * DVAI factory — constructs the embedded HTTP server with offload
 * enabled and forces the v3.0 onPairingRequest callback to flow
 * through PeerMode's MultiTenantPairing layer.
 */
const dvaiFactory: NonNullable<PeerModeOptions["dvaiFactory"]> = (
  onPairingRequest: (peer: DvaiPeerLike) => Promise<boolean>,
): DvaiServerLike => {
  // Build a DVAIConfig that's typed as the union of all backends but
  // populated only with the fields the chosen backend needs. The cast
  // to DvaiServerLike keeps PeerMode's structural decoupling intact.
  const cfg = {
    backend: HUB_BACKEND,
    transformersModelId: HUB_TRANSFORMERS_MODEL,
    device: HUB_DEVICE,
    dtype: HUB_DTYPE,
    ...(HUB_NATIVE_MODEL_PATH !== undefined
      ? { nativeModelPath: HUB_NATIVE_MODEL_PATH }
      : {}),
    ...(HUB_PORT !== undefined ? { httpBasePort: HUB_PORT } : {}),
    transport: "http" as const,
    // Hub binds 0.0.0.0 so paired peers on the LAN can reach it.
    // Defaults can be overridden via DVAI_HUB_BIND_HOST=127.0.0.1 if
    // the operator wants to keep loopback-only for some reason.
    httpBindHost: process.env.DVAI_HUB_BIND_HOST ?? "0.0.0.0",
    // Phase 4 — first-chance interceptor that applies the Hub's
    // substitution policy + engine-bridge routing before falling
    // through to DVAI's default local-backend handler.
    chatCompletionInterceptor: (body: unknown) =>
      chatCompletionInterceptor(body as ChatRequest & { model?: unknown }),
    offload: {
      enabled: true,
      discoverLAN: true,
      // The Hub itself never offloads further upstream — it IS the
      // strong peer. Set minLocalCapability to 0 so any local
      // capability is "good enough" and outgoing-offload never fires.
      minLocalCapability: 0,
      ...(HUB_RENDEZVOUS !== undefined ? { rendezvousUrl: HUB_RENDEZVOUS } : {}),
      onPairingRequest,
    },
  };
  // The DVAI constructor accepts DVAIConfig — cast through unknown to
  // satisfy TypeScript (we don't own the upstream type) and downcast
  // to DvaiServerLike on the way out.
  const dvai = new DVAI(cfg as unknown as ConstructorParameters<typeof DVAI>[0]);
  return dvai as unknown as DvaiServerLike;
};

const peerOptions: PeerModeOptions = {
  storeDir: STORE_DIR,
  externalEnginesEnabled: EXTERNAL_ENGINES_ENABLED,
  engineAdapters: adapters,
  onPairingRequest: (request) => awaitPairingApproval(request),
  onOffloadServed: (audit) => {
    pendingAudit.push(audit);
    notify("offload-served", audit);
  },
  preferBetterQuant: HUB_PREFER_BETTER_QUANT,
  dvaiFactory,
  ...(HUB_RENDEZVOUS !== undefined ? { rendezvousUrl: HUB_RENDEZVOUS } : {}),
  ...(HUB_PORT !== undefined ? { port: HUB_PORT } : {}),
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
    // Populate the Hub's local-backend descriptor so the substitution
    // policy can reason about it. The Hub's local DVAI server only
    // serves the one model configured at boot; that model name parses
    // through the same vocabulary the engine bridge uses.
    peer.setLocalBackends([
      {
        descriptor: parseModelName(HUB_TRANSFORMERS_MODEL),
        engine: "builtin",
        engineModelId: HUB_TRANSFORMERS_MODEL,
      },
    ]);
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
