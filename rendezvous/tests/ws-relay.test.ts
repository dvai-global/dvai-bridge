import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { SessionStore } from "../src/session.js";
import { createContext, handleMessage, handleClose } from "../src/ws-relay.js";
import type { ClientMessage, ServerMessage } from "../src/messages.js";
import type { WebSocket } from "ws";

// Mock WebSocket that captures sent messages.
class MockSocket {
  readonly sent: ServerMessage[] = [];
  readonly closeCalls: Array<{ code: number; reason: string }> = [];
  readyState = 1;
  readonly OPEN = 1;
  send(json: string): void {
    this.sent.push(JSON.parse(json));
  }
  close(code: number, reason: string): void {
    this.closeCalls.push({ code, reason });
    this.readyState = 3;
  }
  on(): void {}
  off(): void {}
}

const send = (ws: MockSocket, msg: ClientMessage) =>
  handleMessage(
    {} as ReturnType<typeof createContext>, // placeholder, replaced per-test
    ws as unknown as WebSocket,
    Buffer.from(JSON.stringify(msg))
  );

describe("ws-relay", () => {
  let store: SessionStore;
  let ctx: ReturnType<typeof createContext>;

  beforeEach(() => {
    store = new SessionStore({ ttlSeconds: 60, maxSessions: 100 });
    ctx = createContext({ rendezvousUrl: "ws://test", sessions: store });
  });

  afterEach(() => {
    store.stop();
  });

  it("ping → pong", () => {
    const ws = new MockSocket();
    handleMessage(ctx, ws as unknown as WebSocket, Buffer.from(JSON.stringify({ type: "ping" })));
    expect(ws.sent).toEqual([{ type: "pong" }]);
  });

  it("malformed JSON → error + close", () => {
    const ws = new MockSocket();
    handleMessage(ctx, ws as unknown as WebSocket, Buffer.from("not json{"));
    expect(ws.sent[0]?.type).toBe("error");
    expect(ws.closeCalls[0]?.code).toBe(1008);
  });

  it("unknown message type → error + close", () => {
    const ws = new MockSocket();
    handleMessage(
      ctx,
      ws as unknown as WebSocket,
      Buffer.from(JSON.stringify({ type: "nope" }))
    );
    expect(ws.sent[0]?.type).toBe("error");
    expect(ws.closeCalls[0]?.code).toBe(1008);
  });

  it("pair-source creates a session and returns QR payload", () => {
    const ws = new MockSocket();
    handleMessage(
      ctx,
      ws as unknown as WebSocket,
      Buffer.from(
        JSON.stringify({
          type: "pair-source",
          deviceId: "A",
          deviceName: "Device A",
          capability: { "Llama-3.2-1B": 25 },
          ephemeralPubKey: "pk-A",
        } satisfies ClientMessage)
      )
    );
    const reply = ws.sent[0];
    expect(reply?.type).toBe("session-created");
    if (reply?.type !== "session-created") return;
    expect(reply.sessionId).toBeTruthy();
    expect(reply.qrPayload).toBeTruthy();
    expect(reply.expiresAt).toBeGreaterThan(Date.now());
  });

  it("end-to-end: source → target → relay forwards encrypted payload", () => {
    const sourceWs = new MockSocket();
    const targetWs = new MockSocket();

    // 1. Source pairs.
    handleMessage(
      ctx,
      sourceWs as unknown as WebSocket,
      Buffer.from(
        JSON.stringify({
          type: "pair-source",
          deviceId: "A",
          deviceName: "Device A",
          capability: { llama: 5 },
          ephemeralPubKey: "pk-A",
        } satisfies ClientMessage)
      )
    );
    const created = sourceWs.sent[0];
    expect(created?.type).toBe("session-created");
    if (created?.type !== "session-created") throw new Error("expected session-created");
    const sessionId = created.sessionId;

    // 2. Target joins.
    handleMessage(
      ctx,
      targetWs as unknown as WebSocket,
      Buffer.from(
        JSON.stringify({
          type: "pair-target",
          sessionId,
          deviceId: "B",
          deviceName: "Device B",
          capability: { llama: 50 },
          ephemeralPubKey: "pk-B",
        } satisfies ClientMessage)
      )
    );

    // Both sides should have received peer-connected.
    const sourcePeerConn = sourceWs.sent.find((m) => m.type === "peer-connected");
    const targetPeerConn = targetWs.sent.find((m) => m.type === "peer-connected");
    expect(sourcePeerConn).toBeDefined();
    expect(targetPeerConn).toBeDefined();
    if (sourcePeerConn?.type === "peer-connected") {
      expect(sourcePeerConn.peerDeviceId).toBe("B");
      expect(sourcePeerConn.peerEphemeralPubKey).toBe("pk-B");
    }
    if (targetPeerConn?.type === "peer-connected") {
      expect(targetPeerConn.peerDeviceId).toBe("A");
      expect(targetPeerConn.peerEphemeralPubKey).toBe("pk-A");
    }

    // 3. Source sends a relay frame; target receives it.
    handleMessage(
      ctx,
      sourceWs as unknown as WebSocket,
      Buffer.from(
        JSON.stringify({
          type: "relay",
          sessionId,
          payload: "OPAQUE-AEAD-DATA",
        } satisfies ClientMessage)
      )
    );
    const relayed = targetWs.sent.find((m) => m.type === "relay");
    expect(relayed).toBeDefined();
    if (relayed?.type === "relay") {
      expect(relayed.from).toBe("source");
      expect(relayed.payload).toBe("OPAQUE-AEAD-DATA");
    }
  });

  it("relay from a socket not in the session → error", () => {
    const ws = new MockSocket();
    handleMessage(
      ctx,
      ws as unknown as WebSocket,
      Buffer.from(
        JSON.stringify({
          type: "relay",
          sessionId: "fake-session",
          payload: "x",
        } satisfies ClientMessage)
      )
    );
    expect(ws.sent[0]?.type).toBe("error");
  });

  it("close event notifies the other peer", () => {
    const sourceWs = new MockSocket();
    const targetWs = new MockSocket();

    handleMessage(
      ctx,
      sourceWs as unknown as WebSocket,
      Buffer.from(
        JSON.stringify({
          type: "pair-source",
          deviceId: "A",
          deviceName: "A",
          capability: {},
          ephemeralPubKey: "pk-A",
        } satisfies ClientMessage)
      )
    );
    const created = sourceWs.sent[0];
    if (created?.type !== "session-created") throw new Error("expected session-created");

    handleMessage(
      ctx,
      targetWs as unknown as WebSocket,
      Buffer.from(
        JSON.stringify({
          type: "pair-target",
          sessionId: created.sessionId,
          deviceId: "B",
          deviceName: "B",
          capability: {},
          ephemeralPubKey: "pk-B",
        } satisfies ClientMessage)
      )
    );

    // Source closes.
    handleClose(ctx, sourceWs as unknown as WebSocket);
    const disconnect = targetWs.sent.find((m) => m.type === "peer-disconnected");
    expect(disconnect).toBeDefined();
  });
});
