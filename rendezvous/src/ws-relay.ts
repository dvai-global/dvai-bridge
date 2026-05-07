/**
 * WebSocket message-handling logic. Pure-ish — takes a SessionStore +
 * incoming WS + raw message, produces side effects (sends responses,
 * closes sockets). Tested against a mock SessionStore.
 */

import type { WebSocket } from "ws";
import type { ClientMessage, ServerMessage } from "./messages.js";
import type { SessionStore, PeerInfo } from "./session.js";

interface RelayContext {
  rendezvousUrl: string;
  sessions: SessionStore;
  /** Map from WebSocket → which session-role this socket holds. */
  socketRole: WeakMap<WebSocket, { sessionId: string; role: "source" | "target" }>;
}

export function createContext(opts: {
  rendezvousUrl: string;
  sessions: SessionStore;
}): RelayContext {
  return {
    rendezvousUrl: opts.rendezvousUrl,
    sessions: opts.sessions,
    socketRole: new WeakMap(),
  };
}

export function handleMessage(
  ctx: RelayContext,
  ws: WebSocket,
  raw: Buffer | ArrayBuffer | Buffer[]
): void {
  let msg: ClientMessage;
  try {
    const text = Buffer.isBuffer(raw)
      ? raw.toString("utf8")
      : Array.isArray(raw)
        ? Buffer.concat(raw).toString("utf8")
        : Buffer.from(raw).toString("utf8");
    msg = JSON.parse(text);
  } catch {
    sendError(ws, "malformed_json", "could not parse JSON");
    ws.close(1008, "malformed_json");
    return;
  }

  if (typeof msg !== "object" || msg === null || typeof msg.type !== "string") {
    sendError(ws, "malformed_message", "missing 'type' field");
    ws.close(1008, "malformed_message");
    return;
  }

  switch (msg.type) {
    case "ping":
      send(ws, { type: "pong" });
      return;

    case "pair-source":
      handlePairSource(ctx, ws, msg);
      return;

    case "pair-target":
      handlePairTarget(ctx, ws, msg);
      return;

    case "relay":
      handleRelay(ctx, ws, msg);
      return;

    default:
      sendError(ws, "unknown_message_type", `unknown type: ${(msg as { type: string }).type}`);
      ws.close(1008, "unknown_message_type");
  }
}

export function handleClose(ctx: RelayContext, ws: WebSocket): void {
  const role = ctx.socketRole.get(ws);
  if (!role) return;
  const session = ctx.sessions.get(role.sessionId);
  if (!session) return;

  // Notify the other peer.
  const other = role.role === "source" ? session.target : session.source;
  if (other) {
    send(other.ws, { type: "peer-disconnected", reason: "peer closed connection" });
  }
  // The session itself stays alive for the TTL window — peer might
  // reconnect. GC will prune if no activity.
}

function handlePairSource(
  ctx: RelayContext,
  ws: WebSocket,
  msg: Extract<ClientMessage, { type: "pair-source" }>
): void {
  const peer: PeerInfo = {
    ws,
    deviceId: msg.deviceId,
    deviceName: msg.deviceName,
    capability: msg.capability,
    ephemeralPubKey: msg.ephemeralPubKey,
  };

  let result;
  try {
    result = ctx.sessions.create(ctx.rendezvousUrl, peer);
  } catch (err) {
    sendError(ws, "server_at_capacity", String(err));
    ws.close(1011, "server_at_capacity");
    return;
  }

  ctx.socketRole.set(ws, { sessionId: result.session.sessionId, role: "source" });

  send(ws, {
    type: "session-created",
    sessionId: result.session.sessionId,
    qrPayload: encodeQrPayload(result.qrPayload),
    expiresAt: result.qrPayload.expiresAt,
  });
}

function handlePairTarget(
  ctx: RelayContext,
  ws: WebSocket,
  msg: Extract<ClientMessage, { type: "pair-target" }>
): void {
  const peer: PeerInfo = {
    ws,
    deviceId: msg.deviceId,
    deviceName: msg.deviceName,
    capability: msg.capability,
    ephemeralPubKey: msg.ephemeralPubKey,
  };

  let session;
  try {
    session = ctx.sessions.joinAsTarget(msg.sessionId, peer);
  } catch (err) {
    sendError(ws, "session_join_failed", String(err));
    ws.close(1008, "session_join_failed");
    return;
  }

  ctx.socketRole.set(ws, { sessionId: session.sessionId, role: "target" });

  // Notify both peers — they each learn the other's ephemeral pub key.
  const source = session.source!;
  send(source.ws, {
    type: "peer-connected",
    peerEphemeralPubKey: peer.ephemeralPubKey,
    peerDeviceId: peer.deviceId,
    peerDeviceName: peer.deviceName,
    peerCapability: peer.capability,
  });
  send(ws, {
    type: "peer-connected",
    peerEphemeralPubKey: source.ephemeralPubKey,
    peerDeviceId: source.deviceId,
    peerDeviceName: source.deviceName,
    peerCapability: source.capability,
  });
}

function handleRelay(
  ctx: RelayContext,
  ws: WebSocket,
  msg: Extract<ClientMessage, { type: "relay" }>
): void {
  const role = ctx.socketRole.get(ws);
  if (!role || role.sessionId !== msg.sessionId) {
    sendError(ws, "session_mismatch", "this socket is not part of that session");
    return;
  }

  const session = ctx.sessions.get(msg.sessionId);
  if (!session) {
    sendError(ws, "session_not_found", "session expired or invalid");
    return;
  }

  ctx.sessions.touch(msg.sessionId);

  const other = role.role === "source" ? session.target : session.source;
  if (!other) {
    sendError(ws, "peer_not_connected", "the other peer hasn't joined yet");
    return;
  }

  send(other.ws, { type: "relay", from: role.role, payload: msg.payload });
}

function send(ws: WebSocket, msg: ServerMessage): void {
  if (ws.readyState !== ws.OPEN) return;
  ws.send(JSON.stringify(msg));
}

function sendError(ws: WebSocket, code: string, message: string): void {
  send(ws, { type: "error", code, message });
}

function encodeQrPayload(payload: object): string {
  return Buffer.from(JSON.stringify(payload), "utf8").toString("base64url");
}
