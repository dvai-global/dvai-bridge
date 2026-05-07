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
