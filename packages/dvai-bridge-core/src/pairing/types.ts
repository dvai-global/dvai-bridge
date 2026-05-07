/**
 * Phase 3 — pairing types. A "pairing" is an authenticated trust
 * relationship between two devices established once via the
 * handshake flow, then reused for all subsequent offload requests
 * via HMAC-signed headers.
 *
 * Pairings expire after `expireAfterDays` (default 30) of inactivity.
 */

export interface Pairing {
  /** Stable per-install device ID of the peer. */
  peerDeviceId: string;
  /** Friendly name for the user UI (revoke / re-pair). */
  peerDeviceName: string;
  /** Shared 256-bit pairing key (base64-url encoded). Used for HMAC. */
  pairingKey: string;
  /** When the pairing was first established. */
  pairedAt: number;
  /** Last time this pairing was used for an offload request. */
  lastUsedAt: number;
  /** Pairing source — informational. */
  via: "lan-handshake" | "rendezvous-qr";
}

export interface PairingStore {
  get(peerDeviceId: string): Promise<Pairing | undefined>;
  set(pairing: Pairing): Promise<void>;
  list(): Promise<Pairing[]>;
  remove(peerDeviceId: string): Promise<void>;
  clear(): Promise<void>;
}

export interface HandshakeRequest {
  originDeviceId: string;
  originDeviceName: string;
  originVersion: string;
  /** Initiator-side ephemeral nonce — included in the HMAC challenge. */
  nonce: string;
}

export interface HandshakeResponse {
  /** Approved? */
  approved: boolean;
  /** If approved, the shared pairing key (base64-url). */
  pairingKey?: string;
  /** If denied, the reason for the diagnostic. */
  reason?: string;
}
