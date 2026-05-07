/**
 * Phase 3 — rendezvous client types. Mirrors the server-side wire
 * protocol in rendezvous/src/messages.ts (kept in sync manually for
 * now; if the protocol grows, share via a published types package).
 */

export type ClientMessage =
  | {
      type: "pair-source";
      deviceId: string;
      deviceName: string;
      capability: Record<string, number>;
      ephemeralPubKey: string;
    }
  | {
      type: "pair-target";
      sessionId: string;
      deviceId: string;
      deviceName: string;
      capability: Record<string, number>;
      ephemeralPubKey: string;
    }
  | { type: "relay"; sessionId: string; payload: string }
  | { type: "ping" };

export type ServerMessage =
  | {
      type: "session-created";
      sessionId: string;
      qrPayload: string;
      expiresAt: number;
    }
  | {
      type: "peer-connected";
      peerEphemeralPubKey: string;
      peerDeviceId: string;
      peerDeviceName: string;
      peerCapability: Record<string, number>;
    }
  | { type: "peer-disconnected"; reason: string }
  | { type: "relay"; from: "source" | "target"; payload: string }
  | { type: "error"; message: string; code: string }
  | { type: "pong" };

export interface QrPayload {
  v: 1;
  rendezvousUrl: string;
  sessionId: string;
  sourceEphemeralPubKey: string;
  sourceDeviceId: string;
  sourceDeviceName: string;
  expiresAt: number;
}

/** Public-facing summary of a peer reached via the rendezvous server. */
export interface RendezvousPeer {
  deviceId: string;
  deviceName: string;
  ephemeralPubKey: string;
  capability: Record<string, number>;
  /** Stub URL — actual offload requests go through the WebSocket relay. */
  relayUrl: string;
  sessionId: string;
}

/** Outcome of a source-side pairing attempt. */
export interface PairingSession {
  sessionId: string;
  qrPayload: string;
  expiresAt: number;
  /** Resolves when the target connects + key exchange completes. */
  waitForPeer: () => Promise<RendezvousPeer>;
  /** Tear down the WebSocket. */
  close: () => void;
}
