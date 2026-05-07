import type { Server } from "node:http";

/** DVAI-reserved base port. Deliberately high to avoid clashes with Ollama/Postgres/etc. */
export const BASE_PORT = 38883;

/** Maximum port-fallback attempts before giving up. */
export const MAX_PORT_ATTEMPTS = 16;

/**
 * Attempt to bind `server` to `basePort`, falling back to basePort+1,
 * basePort+2, ... on EADDRINUSE up to `maxAttempts` times.
 *
 * Default host is `127.0.0.1` (loopback-only) — safe default for any
 * single-device DVAI deployment. v3.0 LAN-target deployments (the
 * v3.1 Hub, native SDKs running in target mode) override to `0.0.0.0`
 * so peers on the same Wi-Fi can reach the server.
 *
 * Throws a loud, actionable error listing the tried range if all are in use.
 * Re-throws non-EADDRINUSE errors immediately (e.g. EACCES on privileged ports).
 *
 * @returns the port that was successfully bound
 */
export async function tryBind(
  server: Server,
  basePort: number = BASE_PORT,
  maxAttempts: number = MAX_PORT_ATTEMPTS,
  host: string = "127.0.0.1",
): Promise<number> {
  for (let i = 0; i < maxAttempts; i++) {
    const port = basePort + i;
    try {
      await new Promise<void>((resolve, reject) => {
        const onError = (err: any) => {
          server.off("error", onError);
          reject(err);
        };
        server.once("error", onError);
        server.listen(port, host, () => {
          server.off("error", onError);
          resolve();
        });
      });
      return port;
    } catch (err: any) {
      if (err.code !== "EADDRINUSE") throw err;
    }
  }
  throw new Error(
    `[DVAI] Could not bind HTTP transport to any port in range ` +
      `${basePort}..${basePort + maxAttempts - 1} (all in use). ` +
      `Another local AI server may already be running.`,
  );
}
