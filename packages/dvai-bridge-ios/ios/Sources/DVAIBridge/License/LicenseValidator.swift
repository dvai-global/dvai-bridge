/*
 * DVAI-Bridge license validator — offline JWT verification on iOS.
 *
 * Mirrors `packages/dvai-bridge-core/src/license/LicenseValidator.ts`:
 *
 *   1. The license is a signed JWT (header + payload + ECDSA P-256
 *      signature), issued by the operator's own license-generator
 *      service from a private key they hold.
 *   2. The SDK ships only with public keys (see `PublicKeys.swift`) and
 *      cannot itself produce valid licenses — so reverse-engineering
 *      the bundled SDK gains nothing.
 *   3. At runtime, the validator does signature + expiry + audience +
 *      platform binding checks. Failure of any check collapses to
 *      free-tier (with attribution badge), not a hard error — the SDK
 *      stays usable for hobbyists / community use UNLESS the caller
 *      uses `validateAndAssert()` (which throws — used by
 *      `DVAIBridge.start(...)` to enforce BSL 1.1).
 *
 * Network calls: zero. The whole flow is offline by design.
 *
 * Algorithm-confusion defense: this validator ONLY accepts ES256.
 * `alg: none`, `HS256`, `RS256` etc. are rejected at the header-parsing
 * step BEFORE handing the token to JWTKit, so a forged header can't
 * trick us into validating against an unintended key.
 */
import Foundation
import JWTKit

public struct LicenseValidatorOptions: Sendable {
    /// Pre-loaded JWT string. Skips filesystem lookups.
    public var token: String?
    /// Explicit path to load from. Overrides auto-discovery.
    public var path: String?
    /// Override the public-key registry. Defaults to `DVAI_PUBLIC_KEYS`
    /// from `PublicKeys.swift`. Tests inject their own keypair via this
    /// option so they can sign + verify against a deterministic key
    /// without polluting the production registry.
    public var publicKeys: [String: DvaiPublicKeyJwk]?
    /// If true, accept tokens signed under `DVAI_PLACEHOLDER_KID`
    /// (i.e. the built-in placeholder public key). Off by default — a
    /// real production build must replace the placeholder with a
    /// generated key. Tests set this to true.
    public var allowPlaceholderKey: Bool
    /// App Group identifier to also search during discovery.
    public var appGroupIdentifier: String?

    public init(
        token: String? = nil,
        path: String? = nil,
        publicKeys: [String: DvaiPublicKeyJwk]? = nil,
        allowPlaceholderKey: Bool = false,
        appGroupIdentifier: String? = nil
    ) {
        self.token = token
        self.path = path
        self.publicKeys = publicKeys
        self.allowPlaceholderKey = allowPlaceholderKey
        self.appGroupIdentifier = appGroupIdentifier
    }
}

/// Validate a DVAI-Bridge license once at SDK startup. The returned
/// `LicenseStatus` is the discriminated value the rest of the SDK
/// dispatches on. `validate()` never throws on validation failure —
/// it returns `.freeProd` / `.freeExpired`. `validateAndAssert()`
/// throws `LicenseRequiredError` for those two cases — used by
/// `DVAIBridge.start(...)` to enforce BSL 1.1.
public final class LicenseValidator: Sendable {
    private let opts: LicenseValidatorOptions

    public init(options: LicenseValidatorOptions = LicenseValidatorOptions()) {
        self.opts = options
    }

    /// Validate WITHOUT throwing. Returns a `LicenseStatus` describing
    /// what the validator determined; never throws on missing /
    /// invalid / expired licenses.
    ///
    /// Useful for host-app dashboards that want to display the
    /// licensee / expiry / fallback reason without halting SDK
    /// startup, and for tests. The SDK's `start(_:)` calls
    /// `validateAndAssert()` instead — which throws.
    ///
    /// Idempotent; safe to call multiple times.
    public func validate() async -> LicenseStatus {
        // 1. Dev-mode bypass — license required only in production.
        let dev = detectDevMode()
        if dev.isDev {
            return .freeDev(reason: dev.reason)
        }

        // 2. Discover the token. Returns nil when no license source is
        //    configured AND auto-discovery fails — fall through to
        //    free-prod so the SDK still works for community / hobbyist
        //    users (and the assert variant can then throw a clear error).
        let discovery = LicenseDiscoveryOptions(
            token: opts.token,
            path: opts.path,
            appGroupIdentifier: opts.appGroupIdentifier
        )
        guard let discovered = discoverLicenseToken(options: discovery) else {
            return .freeProd(reason:
                "no license token found; checked options.token, options.path, " +
                "DVAI_LICENSE_PATH env, DVAI_LICENSE_TOKEN env, Bundle.main " +
                "resource dvai-license.jwt, Application Support / dvai-bridge / " +
                "dvai-license.jwt, and Documents / dvai-license.jwt"
            )
        }

        // 3. Verify signature + claims.
        let platform = detectPlatform()
        let audience = detectAudience()
        return await verifyToken(discovered.token, platform: platform, runtimeAudience: audience)
    }

    /// Strict validation entry point used by the SDK at startup. Returns
    /// `LicenseStatus` on success (`commercial`, `trial`, `freeDev`) and
    /// THROWS `LicenseRequiredError` on `freeProd` / `freeExpired`.
    ///
    /// This is the BSL 1.1 enforcement point: in production / release
    /// builds (any non-dev-mode environment), the SDK refuses to operate
    /// without a valid commercial or trial license. Developers running
    /// in DEBUG / simulator / DVAI_FORCE_DEV are unaffected — those
    /// return a `.freeDev` status and the SDK proceeds normally.
    ///
    /// Use `validate()` when you want to inspect the status without
    /// halting startup (host-app dashboards, test fixtures).
    @discardableResult
    public func validateAndAssert() async throws -> LicenseStatus {
        let status = await validate()
        switch status {
        case .freeProd, .freeExpired:
            throw LicenseRequiredError(
                message: buildRequiredErrorMessage(status: status),
                status: status
            )
        default:
            return status
        }
    }

    // MARK: - Internal: token verification

    private func verifyToken(
        _ token: String,
        platform: DvaiPlatform,
        runtimeAudience: String?
    ) async -> LicenseStatus {
        let registry = opts.publicKeys ?? DVAI_PUBLIC_KEYS

        // Parse the header ourselves to (a) refuse non-ES256 alg early
        // (algorithm-confusion defense — we never even hand a non-ES256
        // token to the JWT library), and (b) pick the right public key
        // by kid before invoking signature verification.
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count != 3 || parts[0].isEmpty {
            return .freeProd(reason: "license token is not a well-formed JWT (need 3 segments)")
        }

        let headerJSON: [String: Any]
        do {
            guard let headerData = base64UrlDecode(String(parts[0])) else {
                return .freeProd(reason: "license token header is not base64url-decodable")
            }
            guard let obj = try JSONSerialization.jsonObject(with: headerData) as? [String: Any] else {
                return .freeProd(reason: "license token header is not a JSON object")
            }
            headerJSON = obj
        } catch {
            return .freeProd(reason: "license token header is not parseable JSON: \(error.localizedDescription)")
        }

        let headerAlg = headerJSON["alg"] as? String
        if headerAlg != "ES256" {
            // Refuse `alg: none` and any non-ES256 algorithm. Critical
            // defense against the classic JWT algorithm-confusion
            // vulnerability.
            return .freeProd(reason:
                "license token uses unsupported alg \"\(headerAlg ?? "(missing)")\", expected ES256"
            )
        }

        guard let kid = headerJSON["kid"] as? String, !kid.isEmpty else {
            return .freeProd(reason: "license token header missing kid; cannot select verification key")
        }

        guard let jwk = registry[kid] else {
            return .freeProd(reason:
                "license token kid \"\(kid)\" is not in the SDK's public-key " +
                "registry; either the key was rotated and you're on an old SDK, " +
                "or the token was signed with a key we don't recognise"
            )
        }

        if kid == DVAI_PLACEHOLDER_KID && !opts.allowPlaceholderKey {
            return .freeProd(reason:
                "license token signed with the placeholder key (kid \"\(DVAI_PLACEHOLDER_KID)\"); " +
                "replace the placeholder in PublicKeys.swift with a real key generated " +
                "via scripts/license/generate-keypair.mjs before issuing real licenses"
            )
        }

        // Hand the (alg-vetted, kid-known) token to JWTKit for signature
        // verification. We register only the matched key — under that
        // kid — so the verifier has no chance to pick anything else.
        let keys = JWTKeyCollection()
        do {
            // ES256PublicKey is JWTKit's public typealias for
            // `ECDSA.PublicKey<P256>` — avoids leaking the swift-crypto
            // `P256` symbol into our source.
            let ecdsaPublic = try ES256PublicKey(parameters: (x: jwk.x, y: jwk.y))
            await keys.add(ecdsa: ecdsaPublic, kid: JWKIdentifier(string: kid))
        } catch {
            return .freeProd(reason:
                "license token kid \"\(kid)\" points at a malformed public key in the SDK's " +
                "registry (could not parse x/y coordinates): \(error.localizedDescription)"
            )
        }

        let payload: DvaiLicensePayload
        do {
            payload = try await keys.verify(token, as: DvaiLicensePayload.self)
        } catch let jwtError as JWTError {
            // JWTKit's signatureVerificationFailed is what we get for a
            // tampered token. Surface it specifically.
            switch jwtError.errorType {
            case .signatureVerificationFailed:
                return .freeProd(reason:
                    "license token signature did not verify against kid \"\(kid)\"; " +
                    "the token may have been tampered with or was signed by a different key"
                )
            case .malformedToken:
                return .freeProd(reason: "license token is malformed: \(jwtError.reason ?? "(no detail)")")
            default:
                return .freeProd(reason: "license token verification failed: \(jwtError)")
            }
        } catch {
            return .freeProd(reason: "license token verification failed: \(error.localizedDescription)")
        }

        // -----------------------------------------------------------------
        // Signature passed. Now run our own claim checks so each failure
        // mode gets a specific, actionable error message.
        // -----------------------------------------------------------------

        // Issuer must be exactly "DVAI-Bridge".
        if payload.iss != "DVAI-Bridge" {
            return .freeProd(reason:
                "license token issuer is \"\(payload.iss)\", expected \"DVAI-Bridge\""
            )
        }

        // Expiry: if exp is in the past, surface a specific freeExpired
        // status (the licensee + when so the dashboard can prompt
        // renewal).
        let nowSeconds = Int64(Date().timeIntervalSince1970)
        if payload.exp <= nowSeconds {
            return .freeExpired(licensee: payload.licensee, expiredAt: payload.exp)
        }

        // Tier must be one of the live tiers.
        let tier: LicenseTier
        switch payload.tier {
        case "commercial": tier = .commercial
        case "trial":      tier = .trial
        default:
            return .freeProd(reason:
                "license token tier \"\(payload.tier)\" is not recognised; " +
                "expected \"commercial\" or \"trial\""
            )
        }

        // Platforms must include our runtime platform.
        if !payload.platforms.contains(platform.rawValue) {
            return .freeProd(reason:
                "license token does not authorise platform \"\(platform.rawValue)\"; " +
                "the token covers [\(payload.platforms.joined(separator: ", "))]"
            )
        }

        // Audience must match (exact / wildcard / *).
        guard let matched = matchAudience(runtimeAudience: runtimeAudience, audClaim: payload.aud) else {
            let noneSuffix = runtimeAudience == nil
                ? " — set DVAI_AUDIENCE in your environment, or use a \"*\" aud entry for any-domain licenses"
                : ""
            return .freeProd(reason:
                "license token's audience entries [\(payload.aud.joined(separator: ", "))] " +
                "do not match the current runtime audience \"\(runtimeAudience ?? "(none)")\"" +
                noneSuffix
            )
        }

        switch tier {
        case .commercial:
            return .commercial(
                licensee: payload.licensee,
                expiresAt: payload.exp,
                platform: platform,
                audienceMatched: matched
            )
        case .trial:
            return .trial(
                licensee: payload.licensee,
                expiresAt: payload.exp,
                platform: platform,
                audienceMatched: matched
            )
        default:
            // Unreachable (we filtered above), but the compiler can't
            // see that.
            return .freeProd(reason: "internal validator state error")
        }
    }
}

// MARK: - Helpers

/// Decode a base64url string (RFC 4648 §5) into raw bytes. The JWT
/// header / payload segments use this encoding (no padding, `-` and `_`
/// instead of `+` and `/`).
private func base64UrlDecode(_ s: String) -> Data? {
    var b64 = s.replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let pad = b64.count % 4
    if pad > 0 {
        b64 += String(repeating: "=", count: 4 - pad)
    }
    return Data(base64Encoded: b64)
}

/// Build the developer-facing error message for `LicenseRequiredError`.
/// Intentionally verbose: it tells the developer exactly what failed,
/// how to resolve it, where to put the license file, and how to bypass
/// for local development. This message will be printed to Xcode's
/// console or a crash log — make it readable in both.
internal func buildRequiredErrorMessage(status: LicenseStatus) -> String {
    let header = """

    DVAI-Bridge Commercial License Required
    =======================================

    """

    let reason: String
    switch status {
    case .freeExpired(let licensee, let expiredAt):
        let date = Date(timeIntervalSince1970: TimeInterval(expiredAt))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        reason = "License for \"\(licensee)\" expired at \(formatter.string(from: date))."
    case .freeProd(let r):
        reason = r
    default:
        reason = "(unknown status)"
    }

    let remediation = """

    This SDK is licensed under BSL 1.1 and requires a valid commercial
    or trial license to run in production / release builds.

    To resolve:
      1. Obtain a license at https://deepvoiceai.com/dvai-bridge/license
      2. Place the file at one of these locations (any will work):
           - <App.bundle>/dvai-license.jwt  (add to Copy Bundle Resources)
           - the path you pass as LicenseValidatorOptions.path
           - the path in $DVAI_LICENSE_PATH
           - inline JWT in LicenseValidatorOptions.token or $DVAI_LICENSE_TOKEN
           - <Application Support>/dvai-bridge/dvai-license.jwt
           - <Documents>/dvai-license.jwt
      3. Re-run.

    Developing locally? The SDK auto-detects dev mode on:
      - DEBUG build configuration (compile-time #if DEBUG)
      - iOS Simulator (compile-time targetEnvironment(simulator))
      - DVAI_FORCE_DEV=1 environment variable (explicit override)
    Any of these silences this error and lets the SDK run without a
    license.

    """

    return header + "\n" + reason + "\n" + remediation
}
