/**
 * Wire-format message types for the dvai-bridge rendezvous protocol.
 *
 * The server is a thin opaque relay. It mediates session creation +
 * key exchange (just relays public keys), then forwards `relay`
 * messages between paired peers. Once paired, both peers do their
 * own AEAD encryption with a derived shared key — the server never
 * sees plaintext inference data.
 */

/** Messages clients send to the server. */
export type ClientMessage =
  /**
   * Sent by the offload-source device (the weak one) to start a
   * pairing session. Server returns `session-created` with a QR
   * payload to display.
   */
  | {
      type: "pair-source";
      deviceId: string;
      deviceName: string;
      capability: Record<string, number>;
      ephemeralPubKey: string; // X25519 base64
    }
  /**
   * Sent by the offload-target device (the strong one) after scanning
   * the QR code. Joins an existing session.
   */
  | {
      type: "pair-target";
      sessionId: string;
      deviceId: string;
      deviceName: string;
      capability: Record<string, number>;
      ephemeralPubKey: string;
    }
  /**
   * Encrypted-payload relay frame. Server doesn't decrypt; just
   * forwards to the peer. Used for inference requests, response
   * chunks, and termination signals.
   */
  | {
      type: "relay";
      sessionId: string;
      payload: string; // base64 of AEAD ciphertext + nonce
    }
  /** Liveness ping. Server replies with `pong`. */
  | { type: "ping" };

/** Messages the server sends to clients. */
export type ServerMessage =
  /**
   * Returned to the source after `pair-source`. The QR payload is the
   * URL-safe-base64-encoded compact JSON the source should encode in
   * a QR code for the target to scan.
   */
  | {
      type: "session-created";
      sessionId: string;
      qrPayload: string;
      expiresAt: number; // unix ms
    }
  /**
   * Sent to BOTH peers once both have connected. Each peer learns the
   * other's public key + identity, derives the shared secret locally
   * via X25519, and stores it for the lifetime of the session.
   */
  | {
      type: "peer-connected";
      peerEphemeralPubKey: string;
      peerDeviceId: string;
      peerDeviceName: string;
      peerCapability: Record<string, number>;
    }
  /** Sent when the other peer disconnects (intentionally or otherwise). */
  | { type: "peer-disconnected"; reason: string }
  /** Forwarded encrypted payload from the peer. */
  | {
      type: "relay";
      from: "source" | "target";
      payload: string;
    }
  /** Server-side error (rate limit, expired session, malformed input). */
  | { type: "error"; message: string; code: string }
  /** Reply to `ping`. */
  | { type: "pong" };

/** QR-payload schema (encoded as URL-safe base64 JSON). */
export interface QrPayload {
  v: 1;
  rendezvousUrl: string;
  sessionId: string;
  sourceEphemeralPubKey: string;
  sourceDeviceId: string;
  sourceDeviceName: string;
  expiresAt: number;
}
