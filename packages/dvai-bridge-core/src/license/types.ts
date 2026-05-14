/**
 * Type surface for the DVAI-Bridge offline JWT license system.
 *
 * The whole license flow is deliberately small:
 *   1. A signed JWT (produced server-side by your license generator) is
 *      either dropped at a platform-default path, pointed at via the
 *      `licenseKeyPath` config option, or pasted directly into the
 *      `licenseToken` config option.
 *   2. The SDK reads it, verifies the ECDSA P-256 signature against the
 *      key registry in `publicKeys.ts`, and checks four runtime claims:
 *      - signature must verify against a known kid
 *      - `exp` must be in the future
 *      - `aud` must include the current audience (hostname / bundleId)
 *      - `platforms` must include the current SDK platform
 *   3. The outcome is summarised in a `LicenseStatus` value that the
 *      rest of the SDK can dispatch on (commercial/trial → premium
 *      behaviour; everything else → free-tier behaviour with the
 *      "Powered by DVAI Bridge" attribution badge).
 *
 * Nothing in this file makes network calls. The entire flow is offline.
 */

/** Recognised license tiers. Free-tier values are produced internally by
 * the validator; commercial / trial come from the signed token's `tier`
 * claim. Anything unknown collapses to "free-prod" defensively. */
export type LicenseTier =
  | "commercial"
  | "trial"
  | "free-dev"      // running on localhost / debug build — no badge required
  | "free-prod"     // production deploy with no valid license — badge required
  | "free-expired"; // had a valid license but `exp` is past — badge required + warn

/** Payload shape we issue (subset; extra claims tolerated). */
export interface DvaiLicensePayload {
  /** Standard JWT issuer claim. Must be `"DVAI-Bridge"`. */
  iss: string;
  /** Standard subject — our internal license id. Surfaced in audit logs. */
  sub: string;
  /** Audience binding — array of domains and/or bundle ids permitted to
   * activate this license. Each entry is either an exact string match
   * (e.g. `"com.acme.app"`) or a wildcard subdomain pattern
   * (e.g. `"*.acme.com"` matches both `acme.com` and `app.acme.com`). */
  aud: string[];
  /** Tier the license grants. `commercial` and `trial` are the live tiers;
   * the validator never produces `free-*` here (those are computed). */
  tier: "commercial" | "trial";
  /** Which DVAI-Bridge SDK platforms this license activates. The current
   * runtime platform must appear here for the license to apply. */
  platforms: DvaiPlatform[];
  /** Display name of the licensee, for audit logs + user-facing messaging. */
  licensee: string;
  /** Standard JWT issued-at (seconds since Unix epoch). */
  iat: number;
  /** Standard JWT expiry (seconds since Unix epoch). */
  exp: number;
}

/** Platform identifiers the SDK recognises in license `platforms` claims. */
export type DvaiPlatform =
  | "web"
  | "node"
  | "ios"
  | "android"
  | "dotnet"
  | "flutter"
  | "react-native"
  | "capacitor";

/**
 * Result of license validation. Discriminated union so the consumer's
 * decision tree is exhaustive ("commercial" or "trial" → premium;
 * everything else → free).
 */
export type LicenseStatus =
  | {
      kind: "commercial";
      licensee: string;
      expiresAt: number;
      platform: DvaiPlatform;
      audienceMatched: string;
    }
  | {
      kind: "trial";
      licensee: string;
      expiresAt: number;
      platform: DvaiPlatform;
      audienceMatched: string;
    }
  | {
      kind: "free-dev";
      /** Why dev mode was detected (for logging / dashboard surfacing). */
      reason: string;
    }
  | {
      kind: "free-prod";
      /** Why a license could not be loaded or validated. Surfaced via a
       * console warning so the developer can debug. Does NOT throw — the
       * SDK falls back to free tier rather than refusing to start. */
      reason: string;
    }
  | {
      kind: "free-expired";
      licensee: string;
      expiredAt: number;
    };

/** Returns true iff `tier` represents a paid / unwatermarked status. */
export function isPaidTier(status: LicenseStatus): boolean {
  return status.kind === "commercial" || status.kind === "trial";
}

/**
 * Thrown by `LicenseValidator.validateAndAssert()` (and propagated from
 * `DVAI.initialize()`) when an SDK consumer attempts to run the library
 * in a production / release context without a valid commercial or trial
 * license.
 *
 * The error message is intentionally verbose: it tells the developer
 * exactly which check failed (missing file, expired, audience mismatch,
 * etc.), how to resolve it, and where to put the license file once
 * they have one. This is the front line of the BSL 1.1 commercial
 * enforcement story — surface it clearly enough that a developer can
 * unblock themselves without a support ticket.
 *
 * The `status` field carries the underlying `LicenseStatus` so
 * programmatic callers can dispatch on `err.status.kind` if they
 * want to handle "expired" differently from "missing".
 */
export class LicenseRequiredError extends Error {
  /** Stable name set so `err.name === "LicenseRequiredError"` works
   *  across module-boundary serialisation (e.g. Vite SSR). */
  override readonly name = "LicenseRequiredError";

  constructor(
    message: string,
    /** The underlying validator status that triggered the throw. */
    public readonly status: LicenseStatus,
  ) {
    super(message);
    // Restore the prototype chain for native-builtin Error in environments
    // (older transpiled CJS targets, some sandboxed iframes) where it
    // gets clobbered. Cheap insurance against `instanceof` surprises.
    Object.setPrototypeOf(this, LicenseRequiredError.prototype);
  }
}
