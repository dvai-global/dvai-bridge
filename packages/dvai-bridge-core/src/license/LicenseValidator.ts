/**
 * DVAI-Bridge license validator — offline JWT verification.
 *
 * This file replaces the v3.2.x `LicenseValidator` that did checksum-
 * style validation on a `dvai-...` plaintext key. The new model:
 *
 *   1. The license is a signed JWT (header + payload + ECDSA P-256
 *      signature), issued by the operator's own license-generator
 *      service from a private key they hold.
 *   2. The SDK ships only with public keys (see `publicKeys.ts`) and
 *      cannot itself produce valid licenses — so reverse-engineering
 *      the bundled SDK gains nothing.
 *   3. At runtime, the validator does signature + expiry + audience +
 *      platform binding checks. Failure of any check collapses to
 *      free-tier (with attribution badge), not a hard error — the SDK
 *      stays usable for hobbyists / community use.
 *
 * Network calls: zero. The whole flow is offline by design — there's
 * no "phone home" step, no license server polling, no DRM beacon. The
 * private-key holder is the only party that can mint tokens, and any
 * deployment that has a valid file activates without contacting us.
 */
import {
  importJWK,
  jwtVerify,
  errors as joseErrors,
  type JWTPayload,
} from "jose";
import {
  DVAI_PUBLIC_KEYS,
  PLACEHOLDER_KID,
  type DvaiPublicKeyJwk,
} from "./publicKeys.js";
import {
  detectAudience,
  detectDevMode,
  detectPlatform,
  matchAudience,
} from "./audience.js";
import {
  discoverLicenseToken,
  type LicenseDiscoveryOptions,
} from "./discovery.js";
import type {
  DvaiLicensePayload,
  DvaiPlatform,
  LicenseStatus,
} from "./types.js";

export interface LicenseValidatorOptions extends LicenseDiscoveryOptions {
  /**
   * Override the public-key registry. Defaults to `DVAI_PUBLIC_KEYS`
   * from `./publicKeys.ts`. Tests inject their own keypair via this
   * option so they can sign + verify against a deterministic key
   * without polluting the production registry.
   */
  publicKeys?: Record<string, DvaiPublicKeyJwk>;
  /**
   * If true, accept tokens signed under `PLACEHOLDER_KID` (i.e. the
   * built-in placeholder public key). Off by default — a real
   * production build must replace the placeholder with a generated
   * key. Tests set this to true.
   */
  allowPlaceholderKey?: boolean;
}

/**
 * Validate a DVAI-Bridge license once at SDK startup. The returned
 * `LicenseStatus` is the discriminated value the rest of the SDK
 * dispatches on. Never throws on validation failure — it logs a
 * console.warn and returns a `free-prod` / `free-expired` status.
 */
export class LicenseValidator {
  private readonly opts: LicenseValidatorOptions;

  constructor(opts: LicenseValidatorOptions = {}) {
    this.opts = opts;
  }

  /** Run the full validation flow. Idempotent; safe to call multiple times. */
  async validate(): Promise<LicenseStatus> {
    // 1. Dev-mode bypass — license required only in production.
    const dev = detectDevMode();
    if (dev.isDev) {
      return { kind: "free-dev", reason: dev.reason };
    }

    // 2. Discover the token. Returns null when no license source is
    //    configured AND auto-discovery fails — fall through to free-prod
    //    so the SDK still works for community / hobbyist users.
    const discovered = await discoverLicenseToken({
      ...(this.opts.token !== undefined ? { token: this.opts.token } : {}),
      ...(this.opts.path !== undefined ? { path: this.opts.path } : {}),
    });
    if (discovered === null) {
      return {
        kind: "free-prod",
        reason:
          "no license token found; checked config.licenseToken, " +
          "config.licenseKeyPath, DVAI_LICENSE_PATH env, " +
          "DVAI_LICENSE_TOKEN env, and platform-default paths",
      };
    }

    // 3. Verify signature + claims with jose.
    const platform = detectPlatform();
    const audience = detectAudience();
    return await this.verifyToken(discovered.token, platform, audience);
  }

  private async verifyToken(
    token: string,
    platform: DvaiPlatform,
    runtimeAudience: string | null,
  ): Promise<LicenseStatus> {
    const registry = this.opts.publicKeys ?? DVAI_PUBLIC_KEYS;

    // Read the kid out of the JWT header to pick the right public key.
    // We could let jose iterate but specifying the key up-front gives
    // clearer error messages on misses.
    let header: { alg?: string; kid?: string };
    try {
      const parts = token.split(".");
      if (parts.length !== 3 || !parts[0]) {
        return {
          kind: "free-prod",
          reason: "license token is not a well-formed JWT (need 3 segments)",
        };
      }
      const headerJson = base64UrlDecodeUtf8(parts[0]);
      header = JSON.parse(headerJson) as { alg?: string; kid?: string };
    } catch (err) {
      return {
        kind: "free-prod",
        reason: `license token header is not parseable JSON: ${asMessage(err)}`,
      };
    }

    if (header.alg !== "ES256") {
      // Refuse `alg: none` and any non-ES256 algorithm. Critical defense
      // against the classic JWT algorithm-confusion vulnerability.
      return {
        kind: "free-prod",
        reason: `license token uses unsupported alg "${header.alg ?? "(missing)"}", expected ES256`,
      };
    }

    if (typeof header.kid !== "string" || header.kid.length === 0) {
      return {
        kind: "free-prod",
        reason: "license token header missing kid; cannot select verification key",
      };
    }

    const jwk = registry[header.kid];
    if (jwk === undefined) {
      return {
        kind: "free-prod",
        reason:
          `license token kid "${header.kid}" is not in the SDK's public-key ` +
          `registry; either the key was rotated and you're on an old SDK, ` +
          `or the token was signed with a key we don't recognise`,
      };
    }

    if (header.kid === PLACEHOLDER_KID && this.opts.allowPlaceholderKey !== true) {
      return {
        kind: "free-prod",
        reason:
          `license token signed with the placeholder key (kid "${PLACEHOLDER_KID}"); ` +
          `replace the placeholder in publicKeys.ts with a real key generated ` +
          `via scripts/license/generate-keypair.mjs before issuing real licenses`,
      };
    }

    let payload: JWTPayload;
    try {
      const key = await importJWK(jwk, "ES256");
      const result = await jwtVerify(token, key, {
        algorithms: ["ES256"],
        issuer: "DVAI-Bridge",
        // Audience and expiry are checked manually below so we can
        // surface specific failure reasons rather than generic
        // jose error codes.
      });
      payload = result.payload;
    } catch (err) {
      // joseErrors gives us typed failure modes — surface the most
      // useful diagnostic per category so the developer's console
      // warning is actionable.
      if (err instanceof joseErrors.JWTExpired) {
        // Expired but otherwise valid — surface the licensee/expiry
        // so the developer knows whose renewal to chase.
        const exp = (err.payload?.exp as number | undefined) ?? 0;
        const licensee = (err.payload?.licensee as string | undefined) ?? "(unknown)";
        return {
          kind: "free-expired",
          licensee,
          expiredAt: exp,
        };
      }
      if (err instanceof joseErrors.JWSSignatureVerificationFailed) {
        return {
          kind: "free-prod",
          reason:
            `license token signature did not verify against kid "${header.kid}"; ` +
            `the token may have been tampered with or was signed by a different key`,
        };
      }
      if (err instanceof joseErrors.JWTClaimValidationFailed) {
        return {
          kind: "free-prod",
          reason: `license token claim "${err.claim}" failed: ${err.reason}`,
        };
      }
      return {
        kind: "free-prod",
        reason: `license token verification failed: ${asMessage(err)}`,
      };
    }

    // Coerce + validate the payload shape ourselves (jose only checks
    // the standard claims). Each branch below provides a specific
    // free-prod reason so the developer can fix exactly what's wrong.
    if (!isLicensePayload(payload)) {
      return {
        kind: "free-prod",
        reason: "license token payload missing required DVAI fields (tier/platforms/aud/licensee)",
      };
    }

    if (!payload.platforms.includes(platform)) {
      return {
        kind: "free-prod",
        reason:
          `license token does not authorise platform "${platform}"; ` +
          `the token covers [${payload.platforms.join(", ")}]`,
      };
    }

    const matched = matchAudience(runtimeAudience, payload.aud);
    if (matched === null) {
      return {
        kind: "free-prod",
        reason:
          `license token's audience entries [${payload.aud.join(", ")}] ` +
          `do not match the current runtime audience "${runtimeAudience ?? "(none)"}"` +
          (runtimeAudience === null
            ? ` — set DVAI_AUDIENCE in your environment, or use a "*" aud entry for any-domain licenses`
            : ""),
      };
    }

    return {
      kind: payload.tier,
      licensee: payload.licensee,
      expiresAt: payload.exp,
      platform,
      audienceMatched: matched,
    };
  }
}

/* -------------------------------------------------------------------------- */
/* Helpers                                                                    */
/* -------------------------------------------------------------------------- */

function isLicensePayload(p: JWTPayload): p is DvaiLicensePayload & JWTPayload {
  return (
    typeof p.iss === "string" &&
    typeof p.sub === "string" &&
    Array.isArray(p.aud) &&
    p.aud.every((a) => typeof a === "string") &&
    (p.tier === "commercial" || p.tier === "trial") &&
    Array.isArray((p as { platforms?: unknown }).platforms) &&
    ((p as { platforms: unknown[] }).platforms).every((x) => typeof x === "string") &&
    typeof (p as { licensee?: unknown }).licensee === "string" &&
    typeof p.iat === "number" &&
    typeof p.exp === "number"
  );
}

function base64UrlDecodeUtf8(s: string): string {
  // Convert base64url → base64, pad, then decode.
  const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/") + pad;
  // Browsers: atob → binary string → UTF-8 via TextDecoder.
  if (typeof atob === "function") {
    const binary = atob(b64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return new TextDecoder().decode(bytes);
  }
  // Node fallback (Buffer is available).
  return Buffer.from(b64, "base64").toString("utf-8");
}

function asMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}
