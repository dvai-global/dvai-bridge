/**
 * Frontend ↔ Tauri ↔ Node-sidecar API bridge.
 *
 * Every dashboard tab calls into this module rather than `invoke()`
 * directly so the IPC method names stay in one place. The Tauri Rust
 * shell forwards each command to the Node sidecar over JSON-RPC.
 */

import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

/* -------------------------------------------------------------------------- */
/* Types — kept in sync with hub/peer-mode/* exports                          */
/* -------------------------------------------------------------------------- */

export interface PeerModeStatus {
  running: boolean;
  port: number | null;
  baseUrl: string | null;
  startedAt: number | null;
}

export interface Pairing {
  appId: string;
  peerDeviceId: string;
  peerDeviceName: string;
  appName?: string;
  pairingKey: string;
  pairedAt: number;
  lastUsedAt: number;
  via: "lan-handshake" | "rendezvous-qr";
}

export interface EngineSummary {
  name: string;
  detected: boolean;
  modelCount: number;
  lastEnumeratedAt: number;
}

export interface OffloadAudit {
  ts: string;
  appId: string;
  peerDeviceId: string;
  engine: string;
  requestedModel: string;
  servedModel: string;
  outcome: "exact" | "substituted" | "refuse";
  reason?: string;
  durationMs?: number;
}

export interface PairingRequestEnvelope {
  requestId: string;
  request: {
    peerDeviceId: string;
    peerDeviceName: string;
    appId: string;
    appName?: string;
    dvaiVersion: string;
  };
}

/** Per-app pairing-policy + future per-app knobs. Stored at
 *  `~/.dvai-hub/apps/<appId>/config.json`. v3.1.x scaffold —
 *  policy enforcement on pairing requests still routes through
 *  the existing approval modal; default mode is `require-approval`. */
export type PairingMode = "always-allow" | "require-approval" | "always-deny";

export interface PerAppConfig {
  appId: string;
  pairingMode: PairingMode;
  rateLimit: {
    /** Reserved for v3.2+. `null` means "no limit". */
    requestsPerMinute: number | null;
  };
  updatedAt: number;
}

/** Model-load progress event from the sidecar. Mirrors the
 *  structured event shape Transformers.js emits natively
 *  (`{"text":"progress_total","progress":...,"timeElapsed":...}`)
 *  with a `phase` discriminator added so we can also carry
 *  llama.cpp-style load progress under the same surface. */
export interface ModelLoadProgress {
  modelId: string;
  /** "downloading" — fetching from network into IndexedDB / disk
   *  "loading"     — hydrating from cache into the runtime
   *  "ready"       — terminal; UI hides the progress bar
   *  "error"       — terminal; UI surfaces the message */
  phase: "downloading" | "loading" | "ready" | "error";
  progress: number;        // 0..1 (1 on phase=ready)
  timeElapsedMs: number;
  message?: string;        // optional human-readable note (e.g. error text)
}

/* -------------------------------------------------------------------------- */
/* Commands                                                                   */
/* -------------------------------------------------------------------------- */

export const api = {
  startPeerMode: (): Promise<PeerModeStatus> => invoke("start_peer_mode"),
  stopPeerMode: (): Promise<{ ok: boolean }> => invoke("stop_peer_mode"),
  getStatus: (): Promise<PeerModeStatus> => invoke("get_status"),
  getPairings: (): Promise<Pairing[]> => invoke("get_pairings"),
  revokePairing: (appId: string, peerDeviceId: string) =>
    invoke<{ ok: boolean }>("revoke_pairing", { appId, peerDeviceId }),
  getEngines: (): Promise<EngineSummary[]> => invoke("get_engines"),
  setEngineEnabled: (name: string, enabled: boolean) =>
    invoke<{ ok: boolean }>("set_engine_enabled", { name, enabled }),
  invalidateEngineCache: (name?: string) =>
    invoke<{ ok: boolean }>("invalidate_engine_cache", { name: name ?? null }),
  respondToPairing: (requestId: string, approved: boolean) =>
    invoke<{ ok: boolean }>("respond_to_pairing", { requestId, approved }),
  getAuditLog: (appId: string, limit?: number): Promise<OffloadAudit[]> =>
    invoke("get_audit_log", { appId, limit: limit ?? null }),

  /* ---- Per-app config (v3.1.x scaffold) ----------------------------- */

  getAppConfig: (appId: string): Promise<PerAppConfig> =>
    invoke("get_app_config", { appId }),
  setAppConfig: (
    appId: string,
    config: Pick<PerAppConfig, "pairingMode" | "rateLimit">,
  ): Promise<{ ok: boolean }> =>
    invoke("set_app_config", { appId, config }),
  revokeAllPairings: (appId: string): Promise<{ ok: boolean }> =>
    invoke("revoke_all_pairings", { appId }),
};

/* -------------------------------------------------------------------------- */
/* Notifications (Tauri events)                                               */
/* -------------------------------------------------------------------------- */

export function onPairingRequest(
  handler: (env: PairingRequestEnvelope) => void,
): Promise<UnlistenFn> {
  return listen<PairingRequestEnvelope>("pairing-request", (event) => {
    handler(event.payload);
  });
}

export function onOffloadServed(
  handler: (audit: OffloadAudit) => void,
): Promise<UnlistenFn> {
  return listen<OffloadAudit>("offload-served", (event) => {
    handler(event.payload);
  });
}

export function onSidecarReady(
  handler: (info: { version: string; pid: number }) => void,
): Promise<UnlistenFn> {
  return listen<{ version: string; pid: number }>("ready", (event) => {
    handler(event.payload);
  });
}

/** Subscribe to model-load progress (Transformers.js + node-llama-cpp).
 *
 *  v3.1.x scaffold — the sidecar emits a single demonstration event on
 *  start so the UI bar is exercisable; full Transformers.js
 *  `progress_callback` and llama.cpp `progressCallback` wiring follows
 *  in a future patch (see `TODO.md` § Hub UX gaps). */
export function onModelLoadProgress(
  handler: (event: ModelLoadProgress) => void,
): Promise<UnlistenFn> {
  return listen<ModelLoadProgress>("model-load-progress", (event) => {
    handler(event.payload);
  });
}
