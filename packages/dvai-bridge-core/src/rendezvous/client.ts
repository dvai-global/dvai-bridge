/**
 * Rendezvous client. Connects to a self-hosted rendezvous server
 * (rendezvous/ in the monorepo) over WebSocket and runs the source
 * or target side of the QR-pairing flow.
 *
 * No transport-specific dep on a Node WebSocket impl — uses the
 * global `WebSocket` constructor available in browsers and Node 22+.
 * Older Node hosts can polyfill via `ws` themselves.
 */

import {
  decodeBase64Url,
  deriveSharedSecret,
  encodeBase64Url,
  generateEphemeralKeyPair,
  type KeyPair,
} from "./keys.js";
import type {
  ClientMessage,
  PairingSession,
  QrPayload,
  RendezvousPeer,
  ServerMessage,
} from "./types.js";

export interface RendezvousClientOptions {
  url: string; // wss://rendezvous.myapp.com (no path; server handles /pair upgrade)
  deviceId: string;
  deviceName: string;
  capability: Record<string, number>;
}

/**
 * Open a source-side pairing session. Returns immediately with a
 * `PairingSession` — display its `qrPayload` as a QR code; await
 * `waitForPeer()` to know when the target completes the handshake.
 */
export async function startAsSource(
  opts: RendezvousClientOptions,
): Promise<PairingSession> {
  const ws = await openWebSocket(`${opts.url}/pair`);
  const keyPair = generateEphemeralKeyPair();

  send(ws, {
    type: "pair-source",
    deviceId: opts.deviceId,
    deviceName: opts.deviceName,
    capability: opts.capability,
    ephemeralPubKey: encodeBase64Url(keyPair.publicKey),
  });

  // Wait for the server's session-created reply.
  const created = await nextMessageOfType<"session-created">(ws, "session-created");

  let resolved = false;
  let pendingPeer: ((peer: RendezvousPeer) => void) | undefined;
  let pendingError: ((err: Error) => void) | undefined;

  ws.addEventListener("message", (ev: MessageEvent) => {
    const msg = parse(ev.data);
    if (!msg) return;
    if (msg.type === "peer-connected" && !resolved) {
      resolved = true;
      pendingPeer?.({
        deviceId: msg.peerDeviceId,
        deviceName: msg.peerDeviceName,
        ephemeralPubKey: msg.peerEphemeralPubKey,
        capability: msg.peerCapability,
        relayUrl: opts.url,
        sessionId: created.sessionId,
      });
    } else if (msg.type === "error" && !resolved) {
      resolved = true;
      pendingError?.(new Error(`rendezvous: ${msg.code} — ${msg.message}`));
    }
  });

  return {
    sessionId: created.sessionId,
    qrPayload: created.qrPayload,
    expiresAt: created.expiresAt,
    waitForPeer: () =>
      new Promise<RendezvousPeer>((resolve, reject) => {
        if (resolved) {
          reject(new Error("session already resolved"));
          return;
        }
        pendingPeer = resolve;
        pendingError = reject;
        // Timeout at the QR expiry.
        const ttl = created.expiresAt - Date.now();
        if (ttl > 0) {
          setTimeout(() => {
            if (!resolved) {
              resolved = true;
              reject(new Error("pairing timed out before peer connected"));
            }
          }, ttl);
        }
      }),
    close: () => {
      try {
        ws.close();
      } catch {
        // ignore — already closed
      }
    },
  };
}

/**
 * Target-side: take a QR payload that was scanned, join the session,
 * complete the handshake, return the source peer's info + the shared
 * secret derived from the ephemeral key exchange.
 */
export async function joinAsTarget(opts: {
  qrPayload: string; // URL-safe base64 of the QR payload JSON
  deviceId: string;
  deviceName: string;
  capability: Record<string, number>;
}): Promise<{ peer: RendezvousPeer; sharedSecret: Uint8Array; ourKeyPair: KeyPair }> {
  const decoded = decodeQrPayload(opts.qrPayload);

  const ws = await openWebSocket(`${decoded.rendezvousUrl}/pair`);
  const keyPair = generateEphemeralKeyPair();

  send(ws, {
    type: "pair-target",
    sessionId: decoded.sessionId,
    deviceId: opts.deviceId,
    deviceName: opts.deviceName,
    capability: opts.capability,
    ephemeralPubKey: encodeBase64Url(keyPair.publicKey),
  });

  const peerConnected = await nextMessageOfType<"peer-connected">(ws, "peer-connected");
  const peerPubKeyBytes = decodeBase64Url(peerConnected.peerEphemeralPubKey);
  const sharedSecret = deriveSharedSecret(keyPair.secretKey, peerPubKeyBytes);

  return {
    peer: {
      deviceId: peerConnected.peerDeviceId,
      deviceName: peerConnected.peerDeviceName,
      ephemeralPubKey: peerConnected.peerEphemeralPubKey,
      capability: peerConnected.peerCapability,
      relayUrl: decoded.rendezvousUrl,
      sessionId: decoded.sessionId,
    },
    sharedSecret,
    ourKeyPair: keyPair,
  };
}

/* -------------------------------------------------------------------------- */
/* Helpers                                                                    */
/* -------------------------------------------------------------------------- */

export function decodeQrPayload(payload: string): QrPayload {
  const decoded = new TextDecoder().decode(decodeBase64Url(payload));
  const parsed = JSON.parse(decoded) as QrPayload;
  if (parsed.v !== 1) {
    throw new Error(`unsupported QR payload version: ${parsed.v}`);
  }
  if (!parsed.rendezvousUrl || !parsed.sessionId) {
    throw new Error("invalid QR payload: missing required fields");
  }
  return parsed;
}

function send(ws: WebSocket, msg: ClientMessage): void {
  ws.send(JSON.stringify(msg));
}

function parse(raw: unknown): ServerMessage | undefined {
  try {
    if (typeof raw === "string") return JSON.parse(raw) as ServerMessage;
    if (raw instanceof ArrayBuffer)
      return JSON.parse(new TextDecoder().decode(raw)) as ServerMessage;
    if (typeof Buffer !== "undefined" && Buffer.isBuffer(raw)) {
      return JSON.parse(raw.toString("utf8")) as ServerMessage;
    }
  } catch {
    return undefined;
  }
  return undefined;
}

async function openWebSocket(url: string): Promise<WebSocket> {
  // Use the global WebSocket — available in browsers + Node 22+.
  // For older runtimes the consumer can polyfill.
  if (typeof WebSocket === "undefined") {
    throw new Error(
      "[DVAI/rendezvous] global WebSocket not available. " +
        "On Node <22, polyfill globalThis.WebSocket = require('ws') before initializing DVAI.",
    );
  }
  const ws = new WebSocket(url);
  await new Promise<void>((resolve, reject) => {
    const onOpen = () => {
      cleanup();
      resolve();
    };
    const onError = (ev: Event) => {
      cleanup();
      reject(new Error(`rendezvous WebSocket failed to open: ${String((ev as ErrorEvent).message ?? ev)}`));
    };
    const cleanup = () => {
      ws.removeEventListener("open", onOpen);
      ws.removeEventListener("error", onError);
    };
    ws.addEventListener("open", onOpen, { once: true });
    ws.addEventListener("error", onError, { once: true });
  });
  return ws;
}

async function nextMessageOfType<TType extends ServerMessage["type"]>(
  ws: WebSocket,
  type: TType,
): Promise<Extract<ServerMessage, { type: TType }>> {
  return new Promise((resolve, reject) => {
    const onMessage = (ev: MessageEvent) => {
      const msg = parse(ev.data);
      if (!msg) return;
      if (msg.type === type) {
        cleanup();
        resolve(msg as Extract<ServerMessage, { type: TType }>);
      } else if (msg.type === "error") {
        cleanup();
        reject(new Error(`rendezvous: ${msg.code} — ${msg.message}`));
      }
    };
    const onClose = () => {
      cleanup();
      reject(new Error("rendezvous WebSocket closed before reply"));
    };
    const cleanup = () => {
      ws.removeEventListener("message", onMessage);
      ws.removeEventListener("close", onClose);
    };
    ws.addEventListener("message", onMessage);
    ws.addEventListener("close", onClose, { once: true });
  });
}
