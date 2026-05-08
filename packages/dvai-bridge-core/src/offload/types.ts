/**
 * Phase 3 — offload module types.
 */

import type { Peer } from "../discovery/types.js";

export type OffloadHeader = "never" | "prefer" | "require";

/** Per-request decision the offload module makes. */
export type Decision =
  | { kind: "local" }
  | { kind: "offload"; peer: Peer }
  | { kind: "no_capable_device"; checked: PeerCheckResult[]; localCapability: number; required: number };

export interface PeerCheckResult {
  deviceId: string;
  deviceName?: string;
  capabilityScore: number;
  reason: string;
}

export interface OffloadConfig {
  /** Master switch. Default false; offload is opt-in at v3.0. */
  enabled: boolean;
  /** Run mDNS to discover LAN peers. */
  discoverLAN: boolean;
  /** Below this tok/s, look for a peer. Default 10. */
  minLocalCapability: number;
  /**
   * v3.2 — hard floor for any local inference, in tok/s. Below this
   * the device is "too weak"; the SDK aborts initialize() and
   * (optionally) shows a system popup via [onHardwareTooWeak].
   *
   * Default: 3. Apps targeting long-prompt batch use cases where
   * latency is acceptable can lower this; apps targeting interactive
   * chat should leave it.
   */
  hardwareMinimum?: number;
  /**
   * v3.2 — host hook fired when the precheck returns `too-weak`.
   * Use this to surface a platform-native alert (UIAlertController,
   * AlertDialog, etc.). The SDK still throws afterward so initialize()
   * fails in a structured way.
   */
  onHardwareTooWeak?: (info: {
    tokPerSec: number;
    hardwareMinimum: number;
    reason: string;
  }) => void | Promise<void>;
  /** Optional rendezvous-server URL — enables internet path if set. */
  rendezvousUrl?: string;
  /** Optional pre-known peers (skip discovery). */
  knownPeers?: Peer[];
  /**
   * Hook to surface pairing-request UI to the host app. Default: deny.
   *
   * Return:
   *   - `true` / `false` — boolean approve/deny. PairingPolicy generates
   *     a fresh pairingKey on approval.
   *   - `{ approved: true, pairingKey }` — host has its own pairing
   *     state (the v3.1 Hub's MultiTenantPairing) and wants the
   *     library to use the host-supplied key. Avoids the library
   *     generating a key that diverges from the host's store.
   *   - `{ approved: false }` — denied.
   */
  onPairingRequest?: (
    peer: Peer,
  ) => Promise<
    | boolean
    | { approved: true; pairingKey: string }
    | { approved: false }
  >;
  /** Diagnostic callback when a request is offloaded. */
  onOffload?: (peer: Peer) => void;
  /** Hook to plug a custom discovery source. */
  customDiscovery?: () => Promise<Peer[]>;
}

/** OpenAI-error-shaped response body for `no_capable_device`. */
export interface NoCapableDeviceErrorBody {
  error: {
    type: "no_capable_device";
    code: number;
    message: string;
    checked: PeerCheckResult[];
    localCapability: number;
    requiredAtLeast: number;
    rendezvousConfigured: boolean;
    pairedRemotePeers: number;
    requestId?: string;
  };
}
