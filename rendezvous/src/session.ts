/**
 * In-memory session store. Sessions expire after `SESSION_TTL_SECONDS`
 * of inactivity (last message). No persistence; if the server restarts,
 * all sessions die. Clients must handle reconnect by re-pairing.
 *
 * For >10k concurrent sessions or multi-instance horizontal scaling,
 * swap this for a Redis-backed store (v3.2+ work).
 */

import { randomBytes } from "node:crypto";
import type { WebSocket } from "ws";
import type { QrPayload } from "./messages.js";

export interface Session {
  readonly sessionId: string;
  readonly createdAt: number;
  lastActivityAt: number;
  source?: PeerInfo;
  target?: PeerInfo;
}

export interface PeerInfo {
  ws: WebSocket;
  deviceId: string;
  deviceName: string;
  capability: Record<string, number>;
  ephemeralPubKey: string;
}

export class SessionStore {
  private readonly sessions = new Map<string, Session>();
  private readonly ttlMs: number;
  private readonly maxSessions: number;
  private gcTimer?: NodeJS.Timeout;

  constructor(opts: { ttlSeconds: number; maxSessions: number }) {
    this.ttlMs = opts.ttlSeconds * 1000;
    this.maxSessions = opts.maxSessions;
  }

  start(): void {
    // GC every 10 seconds. Cheap; just iterates the Map and prunes expired.
    this.gcTimer = setInterval(() => this.gc(), 10_000);
  }

  stop(): void {
    if (this.gcTimer) clearInterval(this.gcTimer);
    this.gcTimer = undefined;
    this.sessions.clear();
  }

  create(rendezvousUrl: string, source: PeerInfo): {
    session: Session;
    qrPayload: QrPayload;
  } {
    if (this.sessions.size >= this.maxSessions) {
      throw new Error("server at capacity (MAX_SESSIONS reached)");
    }

    const sessionId = randomBytes(16).toString("base64url");
    const now = Date.now();
    const session: Session = {
      sessionId,
      createdAt: now,
      lastActivityAt: now,
      source,
    };
    this.sessions.set(sessionId, session);

    const qrPayload: QrPayload = {
      v: 1,
      rendezvousUrl,
      sessionId,
      sourceEphemeralPubKey: source.ephemeralPubKey,
      sourceDeviceId: source.deviceId,
      sourceDeviceName: source.deviceName,
      expiresAt: now + this.ttlMs,
    };

    return { session, qrPayload };
  }

  get(sessionId: string): Session | undefined {
    return this.sessions.get(sessionId);
  }

  joinAsTarget(sessionId: string, target: PeerInfo): Session {
    const session = this.sessions.get(sessionId);
    if (!session) {
      throw new Error(`session ${sessionId} not found or expired`);
    }
    if (session.target) {
      throw new Error(`session ${sessionId} already has a target`);
    }
    session.target = target;
    session.lastActivityAt = Date.now();
    return session;
  }

  touch(sessionId: string): void {
    const session = this.sessions.get(sessionId);
    if (session) session.lastActivityAt = Date.now();
  }

  remove(sessionId: string): void {
    this.sessions.delete(sessionId);
  }

  size(): number {
    return this.sessions.size;
  }

  /** Internal GC pass — prunes sessions past TTL. */
  private gc(): void {
    const cutoff = Date.now() - this.ttlMs;
    for (const [id, session] of this.sessions) {
      if (session.lastActivityAt < cutoff) {
        try {
          session.source?.ws.close(1000, "session expired");
          session.target?.ws.close(1000, "session expired");
        } catch {
          // sockets may already be dead; ignore
        }
        this.sessions.delete(id);
      }
    }
  }
}
