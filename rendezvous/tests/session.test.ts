import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { SessionStore, type PeerInfo } from "../src/session.js";
import type { WebSocket } from "ws";

// Minimal WebSocket stub — we only need the close() shape for these tests.
const stubWs = (): WebSocket =>
  ({ close: () => {}, readyState: 1, send: () => {}, OPEN: 1 }) as unknown as WebSocket;

const peer = (deviceId: string): PeerInfo => ({
  ws: stubWs(),
  deviceId,
  deviceName: `device-${deviceId}`,
  capability: { "Llama-3.2-1B": 25 },
  ephemeralPubKey: `pk-${deviceId}`,
});

describe("SessionStore", () => {
  let store: SessionStore;

  beforeEach(() => {
    store = new SessionStore({ ttlSeconds: 60, maxSessions: 100 });
  });

  afterEach(() => {
    store.stop();
  });

  it("creates a session and returns a QR payload", () => {
    const { session, qrPayload } = store.create("ws://localhost:8080", peer("A"));
    expect(session.sessionId).toMatch(/^[A-Za-z0-9_-]+$/);
    expect(qrPayload.rendezvousUrl).toBe("ws://localhost:8080");
    expect(qrPayload.sourceDeviceId).toBe("A");
    expect(qrPayload.expiresAt).toBeGreaterThan(Date.now());
    expect(store.size()).toBe(1);
  });

  it("rejects new sessions past MAX_SESSIONS", () => {
    const small = new SessionStore({ ttlSeconds: 60, maxSessions: 2 });
    small.create("ws://x", peer("A"));
    small.create("ws://x", peer("B"));
    expect(() => small.create("ws://x", peer("C"))).toThrow(/capacity/i);
    small.stop();
  });

  it("joinAsTarget links the second peer", () => {
    const { session } = store.create("ws://x", peer("A"));
    const joined = store.joinAsTarget(session.sessionId, peer("B"));
    expect(joined.target?.deviceId).toBe("B");
    expect(joined.source?.deviceId).toBe("A");
  });

  it("joinAsTarget rejects an unknown sessionId", () => {
    expect(() => store.joinAsTarget("nonexistent", peer("B"))).toThrow(/not found/i);
  });

  it("joinAsTarget rejects a session that already has a target", () => {
    const { session } = store.create("ws://x", peer("A"));
    store.joinAsTarget(session.sessionId, peer("B"));
    expect(() => store.joinAsTarget(session.sessionId, peer("C"))).toThrow(/already/i);
  });

  it("touch updates lastActivityAt", () => {
    const { session } = store.create("ws://x", peer("A"));
    const initial = session.lastActivityAt;
    // Wait a tick — Date.now() resolution is millisecond.
    const before = Date.now();
    while (Date.now() === before) {} // busy-wait one ms
    store.touch(session.sessionId);
    expect(session.lastActivityAt).toBeGreaterThan(initial);
  });

  it("remove deletes a session", () => {
    const { session } = store.create("ws://x", peer("A"));
    expect(store.size()).toBe(1);
    store.remove(session.sessionId);
    expect(store.size()).toBe(0);
    expect(store.get(session.sessionId)).toBeUndefined();
  });
});
