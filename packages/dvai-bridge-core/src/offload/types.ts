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
  /** Optional rendezvous-server URL — enables internet path if set. */
  rendezvousUrl?: string;
  /** Optional pre-known peers (skip discovery). */
  knownPeers?: Peer[];
  /** Hook to surface pairing-request UI to the host app. Default: deny. */
  onPairingRequest?: (peer: Peer) => Promise<boolean>;
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
