/**
 * License-file discovery for the JS/TS SDK.
 *
 * The SDK reads the license JWT from (in priority order):
 *
 *   1. An explicit string literal passed as `licenseToken` in DVAIConfig
 *      — useful for CI / serverless / contexts where reading a file isn't
 *      practical and the operator wants to inject via env var instead.
 *
 *   2. A path passed as `licenseKeyPath` in DVAIConfig — the developer
 *      points the SDK at a file they've placed somewhere non-default.
 *
 *   3. The `DVAI_LICENSE_PATH` env var — same as (2) but driven by
 *      process environment, helpful for containerised deployments.
 *
 *   4. Auto-discovery from platform-default locations (see below) —
 *      the dev-friendly happy path. Drop the file at the convention
 *      location and forget about it.
 *
 * Default discovery paths per JS-side platform:
 *
 *   - **Node.js**: looks for `dvai-license.jwt` in `process.cwd()` and
 *     in `<package-root>/dvai-license.jwt` (one level up). Mirrors how
 *     `.env` files are discovered.
 *
 *   - **Browser**: fetches `/dvai-license.jwt` from the same origin. The
 *     file must be served alongside `mockServiceWorker.js` — typically
 *     in `public/` for Vite/Webpack apps. The HTTP fetch is cached by
 *     the browser so this is one round-trip on startup, not per request.
 *
 *   - **Capacitor**: fetches `/dvai-license.jwt` from the bundled web
 *     assets (Capacitor.convertFileSrc on the public/ folder). The
 *     native-side validator (in DVAIBridge.iOS / .Android) is the
 *     authoritative binding for native bundle ids; this JS-side check
 *     is a soft signal only.
 *
 * Returning `null` means "no license file found"; the validator treats
 * that as the free-tier case (after dev-mode bypass).
 */

/**
 * Default filename the SDK looks for. Chosen to be self-documenting and
 * to encourage commit-to-vcs (so the license travels with the code,
 * audited and reviewable by the team).
 */
export const DEFAULT_LICENSE_FILENAME = "dvai-license.jwt";

export interface LicenseDiscoveryOptions {
  /** Pre-loaded JWT string (skips all filesystem / fetch lookups). */
  token?: string;
  /** Explicit path or URL to load from. Overrides auto-discovery. */
  path?: string;
}

/**
 * Best-effort load of a license JWT. Returns the raw token string on
 * success or null on miss. Errors during loading (file not found,
 * network timeout) collapse to null — the validator's responsibility
 * is to handle the no-license case gracefully, not the discovery
 * layer's.
 */
export async function discoverLicenseToken(
  opts: LicenseDiscoveryOptions = {},
): Promise<{ token: string; source: string } | null> {
  // 1. Explicit token wins.
  if (typeof opts.token === "string" && opts.token.length > 0) {
    return { token: opts.token.trim(), source: "config.licenseToken" };
  }

  // 2. Explicit path (config option).
  if (typeof opts.path === "string" && opts.path.length > 0) {
    const loaded = await tryLoadFromPath(opts.path);
    if (loaded !== null) return { token: loaded, source: opts.path };
    return null; // explicit path that didn't load is a real miss, not a silent fallthrough
  }

  // 3. Env-var path.
  if (typeof process !== "undefined" && process.env?.DVAI_LICENSE_PATH) {
    const envPath = process.env.DVAI_LICENSE_PATH;
    const loaded = await tryLoadFromPath(envPath);
    if (loaded !== null) return { token: loaded, source: `DVAI_LICENSE_PATH=${envPath}` };
  }

  // 4. Env-var inline token (alternative to file for serverless).
  if (typeof process !== "undefined" && process.env?.DVAI_LICENSE_TOKEN) {
    return {
      token: process.env.DVAI_LICENSE_TOKEN.trim(),
      source: "DVAI_LICENSE_TOKEN env var",
    };
  }

  // 5. Platform default-location auto-discovery.
  return await tryAutoDiscover();
}

async function tryLoadFromPath(p: string): Promise<string | null> {
  // URLs (browser + Node 18+ fetch) — anything with a scheme.
  if (/^https?:\/\//i.test(p)) {
    return await tryFetch(p);
  }
  // Otherwise treat as filesystem path. Use a dynamic import so this
  // module stays browser-safe; `fs/promises` is only imported when we're
  // actually about to read a path.
  return await tryFsRead(p);
}

async function tryFetch(url: string): Promise<string | null> {
  try {
    const res = await fetch(url, { method: "GET" });
    if (!res.ok) return null;
    const text = (await res.text()).trim();
    return text.length > 0 ? text : null;
  } catch {
    return null;
  }
}

async function tryFsRead(path: string): Promise<string | null> {
  try {
    // Dynamic import keeps `fs/promises` out of the browser bundle.
    // tsup/vite will tree-shake this out when bundling for web.
    const fs = await import("node:fs/promises");
    const buf = await fs.readFile(path, "utf-8");
    const text = buf.trim();
    return text.length > 0 ? text : null;
  } catch {
    return null;
  }
}

async function tryAutoDiscover(): Promise<{ token: string; source: string } | null> {
  // Browser / Capacitor: try same-origin /dvai-license.jwt.
  if (typeof window !== "undefined") {
    const sameOriginUrl = `/${DEFAULT_LICENSE_FILENAME}`;
    const loaded = await tryFetch(sameOriginUrl);
    if (loaded !== null) return { token: loaded, source: sameOriginUrl };
    return null;
  }

  // Node: try cwd, then one level up (monorepo root case).
  if (typeof process !== "undefined" && typeof process.cwd === "function") {
    const path = await import("node:path").catch(() => null);
    if (path === null) return null;
    const candidates = [
      path.join(process.cwd(), DEFAULT_LICENSE_FILENAME),
      path.join(process.cwd(), "..", DEFAULT_LICENSE_FILENAME),
    ];
    for (const c of candidates) {
      const loaded = await tryFsRead(c);
      if (loaded !== null) return { token: loaded, source: c };
    }
  }
  return null;
}
