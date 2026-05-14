/**
 * Runtime audience + platform + dev-mode detection for the JS/TS SDK.
 *
 * Native SDKs (iOS, Android, .NET, Flutter) re-implement this in their
 * own languages — the semantics are the same but the platform APIs
 * differ. Each native validator detects its own audience (bundle id /
 * package name / assembly name) and its own platform identifier.
 *
 * For the JS/TS SDK, "audience" means:
 *   - in a browser: window.location.hostname
 *   - under Capacitor: the native platform's bundle id (read via the
 *     Capacitor bridge if available, otherwise falls back to hostname)
 *   - under React Native: deferred — the RN SDK's validator handles this
 *   - in Node: process.env.DVAI_AUDIENCE (operator-supplied), else null
 *     (Node deployments without an explicit audience can't be domain-
 *     bound, so the license aud check is permissive — see validator)
 *
 * "Dev mode" detection bypasses license enforcement entirely so
 * developers don't need a license to run the SDK on localhost or in a
 * debug build. This matches the prior LicenseValidator behaviour and
 * keeps the developer-experience curve gentle.
 */
import type { DvaiPlatform } from "./types.js";

/** Detect the current SDK platform identifier. Best-effort; returns
 *  the most specific known platform that matches the runtime. */
export function detectPlatform(): DvaiPlatform {
  // Capacitor is detected before browser because a Capacitor app *is*
  // a browser environment with a Capacitor global attached. Order matters.
  if (typeof globalThis !== "undefined") {
    const g = globalThis as unknown as {
      Capacitor?: { isNativePlatform?: () => boolean };
      process?: { versions?: { node?: string } };
      window?: unknown;
    };
    if (g.Capacitor?.isNativePlatform?.()) return "capacitor";
    if (g.process?.versions?.node && typeof g.window === "undefined") {
      return "node";
    }
  }
  if (typeof window !== "undefined" && typeof document !== "undefined") {
    return "web";
  }
  // Fall back to "node" — workers and exotic JS hosts get folded in here.
  // The audience binding is the load-bearing check; platform is a coarse
  // filter, so over-permissiveness here is acceptable.
  return "node";
}

/** Detect the current audience string the license must bind. Returns
 *  null when no determinable audience exists (e.g. headless Node) —
 *  the validator handles null by accepting any aud entry, since binding
 *  enforcement requires a concrete runtime identifier to match against. */
export function detectAudience(): string | null {
  // Browser-like environments report the hostname. Capacitor reports
  // `localhost` (the bundled-content origin) which is intentionally
  // matched against the license's aud entries — Capacitor apps that
  // want native-bundle-id binding should use the native SDK's validator
  // (running below the bridge) rather than the JS-side one.
  if (typeof window !== "undefined") {
    const w = window as unknown as { location?: { hostname?: string } };
    const host = w.location?.hostname;
    if (typeof host === "string" && host.length > 0) return host;
  }
  // Node.js explicit override — operators set this on the process so
  // server-side deployments can opt in to license binding.
  if (typeof process !== "undefined" && process.env?.DVAI_AUDIENCE) {
    return process.env.DVAI_AUDIENCE;
  }
  return null;
}

/**
 * Detect whether the SDK is running in a developer environment where
 * license enforcement should be bypassed. The bypass list is intentionally
 * generous: blocking a developer mid-`pnpm dev` with a license-not-found
 * error would be hostile. The cost is that a malicious actor pointing
 * their build at `localhost` could bypass — but they could equally fork
 * the SDK and remove the check, so the dev-mode bypass adds no real
 * attack surface.
 */
export function detectDevMode(): { isDev: boolean; reason: string } {
  // 1. Explicit env-var override wins.
  if (typeof process !== "undefined" && process.env) {
    if (process.env.DVAI_FORCE_PROD === "1" || process.env.DVAI_FORCE_PROD === "true") {
      return { isDev: false, reason: "DVAI_FORCE_PROD set" };
    }
    if (process.env.DVAI_FORCE_DEV === "1" || process.env.DVAI_FORCE_DEV === "true") {
      return { isDev: true, reason: "DVAI_FORCE_DEV set" };
    }
    if (process.env.NODE_ENV === "test") {
      return { isDev: true, reason: "NODE_ENV=test" };
    }
  }

  // 2. Capacitor / Cordova debug flags.
  const g = (typeof globalThis !== "undefined" ? globalThis : {}) as Record<string, unknown>;
  const cap = g["Capacitor"] as { DEBUG?: boolean } | undefined;
  if (cap?.DEBUG === true) {
    return { isDev: true, reason: "Capacitor.DEBUG=true" };
  }

  // 3. Localhost / private-network / .local mDNS hostnames in the browser.
  //    Matches the prior LicenseValidator's heuristic so v3.2.x apps that
  //    used to bypass licensing on dev URLs continue to bypass.
  if (typeof window !== "undefined") {
    const w = window as unknown as { location?: { hostname?: string } };
    const host = w.location?.hostname ?? "";
    if (
      host === "localhost" ||
      host === "127.0.0.1" ||
      host === "::1" ||
      host.endsWith(".local") ||
      host.startsWith("192.168.") ||
      host.startsWith("10.") ||
      host.startsWith("172.")
    ) {
      return { isDev: true, reason: `localhost-class hostname: ${host}` };
    }
    // 4. localStorage override (browser-only test hook).
    try {
      const ls = (window as unknown as { localStorage?: Storage }).localStorage;
      if (ls?.getItem("DVAI_FORCE_PROD") === "true") {
        return { isDev: false, reason: "localStorage DVAI_FORCE_PROD=true" };
      }
      if (ls?.getItem("DVAI_FORCE_DEV") === "true") {
        return { isDev: true, reason: "localStorage DVAI_FORCE_DEV=true" };
      }
    } catch {
      /* sandboxed contexts (some iframes) throw on storage access */
    }
  }

  return { isDev: false, reason: "production-class environment" };
}

/**
 * Decide whether a license-payload `aud` entry matches the current
 * runtime audience. Supports exact match and `*.example.com` wildcard
 * matching for subdomain binding. Returns the matched `aud` pattern
 * on success so it can be recorded for audit, or null on miss.
 *
 * Match rules:
 *   - "foo" matches "foo" exactly
 *   - "*.example.com" matches "example.com" AND any "<sub>.example.com"
 *   - "*" matches any non-empty audience (intentionally permissive; use
 *     for trial/site licenses that span all of a customer's deployments)
 *
 * Runtime audience of `null` matches `"*"` only — a Node deployment
 * without DVAI_AUDIENCE set can activate "any-domain" licenses but
 * not domain-bound ones. This is the safe default; operators that
 * want stricter binding set DVAI_AUDIENCE explicitly.
 */
export function matchAudience(
  runtimeAudience: string | null,
  audClaim: string[],
): string | null {
  if (runtimeAudience === null) {
    return audClaim.includes("*") ? "*" : null;
  }
  const runtime = runtimeAudience.toLowerCase();
  for (const pattern of audClaim) {
    const p = pattern.toLowerCase();
    if (p === "*") return pattern; // permissive wildcard
    if (p === runtime) return pattern; // exact match
    if (p.startsWith("*.")) {
      const suffix = p.slice(2);
      if (runtime === suffix || runtime.endsWith("." + suffix)) {
        return pattern;
      }
    }
  }
  return null;
}
