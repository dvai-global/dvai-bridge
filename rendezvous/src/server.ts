/**
 * dvai-bridge rendezvous server — entry point.
 *
 * A thin WebSocket relay that mediates QR-pairing between two devices
 * running dvai-bridge across different networks. Stateless beyond
 * per-session memory; no database; no auth tokens; no plaintext
 * inference data ever passes through here (peers do their own AEAD).
 *
 * Configuration via env vars (see .env.example).
 */

import Fastify from "fastify";
import websocketPlugin from "@fastify/websocket";
import { SessionStore } from "./session.js";
import { createContext, handleClose, handleMessage } from "./ws-relay.js";

const PORT = Number.parseInt(process.env.PORT ?? "8080", 10);
const HOST = process.env.HOST ?? "0.0.0.0";
const SESSION_TTL_SECONDS = Number.parseInt(process.env.SESSION_TTL_SECONDS ?? "60", 10);
const MAX_SESSIONS = Number.parseInt(process.env.MAX_SESSIONS ?? "10000", 10);
const LOG_LEVEL = process.env.LOG_LEVEL ?? "info";
const ALLOWED_ORIGINS = process.env.ALLOWED_ORIGINS ?? "*";
const METRICS_ENABLED = process.env.METRICS_ENABLED === "1";
const RENDEZVOUS_URL = process.env.RENDEZVOUS_URL ?? `ws://${HOST}:${PORT}`;

const app = Fastify({ logger: { level: LOG_LEVEL } });
await app.register(websocketPlugin);

const sessions = new SessionStore({ ttlSeconds: SESSION_TTL_SECONDS, maxSessions: MAX_SESSIONS });
sessions.start();

const ctx = createContext({ rendezvousUrl: RENDEZVOUS_URL, sessions });

const startedAt = Date.now();

app.get("/health", async () => ({
  status: "ok",
  activeSessions: sessions.size(),
  uptimeSec: Math.floor((Date.now() - startedAt) / 1000),
  version: "0.1.0",
}));

if (METRICS_ENABLED) {
  app.get("/metrics", async (_req, reply) => {
    reply.type("text/plain; version=0.0.4");
    return [
      `# HELP rendezvous_active_sessions Active pairing sessions`,
      `# TYPE rendezvous_active_sessions gauge`,
      `rendezvous_active_sessions ${sessions.size()}`,
      `# HELP rendezvous_uptime_seconds Server uptime in seconds`,
      `# TYPE rendezvous_uptime_seconds counter`,
      `rendezvous_uptime_seconds ${Math.floor((Date.now() - startedAt) / 1000)}`,
      "",
    ].join("\n");
  });
}

app.get("/pair", { websocket: true }, (socket /* SocketStream */, req) => {
  const origin = req.headers.origin;
  if (
    ALLOWED_ORIGINS !== "*" &&
    origin &&
    !ALLOWED_ORIGINS.split(",").includes(origin)
  ) {
    socket.close(1008, "origin_not_allowed");
    return;
  }

  socket.on("message", (raw: Buffer | ArrayBuffer | Buffer[]) => {
    handleMessage(ctx, socket, raw);
  });

  socket.on("close", () => {
    handleClose(ctx, socket);
  });

  socket.on("error", (err: Error) => {
    app.log.warn({ err }, "websocket error");
  });
});

app.get("/", async () => ({
  service: "dvai-bridge-rendezvous",
  version: "0.1.0",
  pair: "/pair (WebSocket)",
  health: "/health",
  metrics: METRICS_ENABLED ? "/metrics" : "(disabled)",
}));

const shutdown = async (signal: string) => {
  app.log.info({ signal }, "shutting down");
  sessions.stop();
  await app.close();
  process.exit(0);
};
process.on("SIGTERM", () => void shutdown("SIGTERM"));
process.on("SIGINT", () => void shutdown("SIGINT"));

try {
  await app.listen({ port: PORT, host: HOST });
  app.log.info(
    { port: PORT, host: HOST, rendezvousUrl: RENDEZVOUS_URL, sessionTtl: SESSION_TTL_SECONDS },
    "rendezvous server listening"
  );
} catch (err) {
  app.log.error(err);
  process.exit(1);
}
