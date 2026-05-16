/*
 * Type surface for the DVAI-Bridge offline JWT license system on iOS.
 *
 * Mirrors `packages/dvai-bridge-core/src/license/types.ts`. The whole
 * license flow is deliberately small:
 *   1. A signed JWT (produced server-side by your license generator) is
 *      either dropped at a platform-default path (e.g. bundled as a
 *      `dvai-license.jwt` resource), pointed at via
 *      `LicenseValidatorOptions.path`, or pasted directly into
 *      `LicenseValidatorOptions.token`.
 *   2. The SDK reads it, verifies the ECDSA P-256 signature against the
 *      key registry in `PublicKeys.swift`, and checks four runtime
 *      claims:
 *        - signature must verify against a known kid
 *        - `exp` must be in the future
 *        - `aud` must include the current audience (Bundle.main.bundleIdentifier)
 *        - `platforms` must include the current SDK platform (.ios)
 *   3. The outcome is summarised in a `LicenseStatus` value the rest of
 *      the SDK can dispatch on.
 *
 * Nothing in this file makes network calls. The entire flow is offline.
 *
 * The wire format (JWT header + payload + ES256 signature) is byte-for-
 * byte equivalent to the JS-side validator — the same .jwt file works
 * across iOS, Android, .NET, Flutter, RN, and JS SDKs.
 */
import Foundation
#if !COCOAPODS
import JWTKit
#endif

/// Recognised license tiers. `commercial` and `trial` come from the
/// signed token's `tier` claim; the `free*` variants are produced
/// internally by the validator. Anything unknown collapses to
/// `.freeProd` defensively.
public enum LicenseTier: String, Sendable, Codable, Equatable {
    case commercial
    case trial
    /// Running in DEBUG / simulator / DVAI_FORCE_DEV — no badge required.
    case freeDev = "free-dev"
    /// Production build with no valid license — badge required.
    case freeProd = "free-prod"
    /// Had a valid license but `exp` is past — badge required + warn.
    case freeExpired = "free-expired"
}

/// Platform identifiers the SDK recognises in license `platforms` claims.
/// Matches the JS-side enum exactly so a single .jwt activates across
/// every SDK that lists its identifier.
public enum DvaiPlatform: String, Sendable, Codable, Equatable {
    case web
    case node
    case ios
    case android
    case dotnet
    case flutter
    case reactNative = "react-native"
    case capacitor
}

/// Result of license validation. Use the `kind` case to dispatch — the
/// associated values vary per case (matching the JS-side discriminated
/// union exactly).
public enum LicenseStatus: Sendable, Equatable {
    /// Active commercial license. Audience + platform binding verified.
    case commercial(licensee: String, expiresAt: Int64, platform: DvaiPlatform, audienceMatched: String)

    /// Active trial license. Same shape as commercial — the SDK treats
    /// both as "premium" (no attribution badge).
    case trial(licensee: String, expiresAt: Int64, platform: DvaiPlatform, audienceMatched: String)

    /// Running in a developer environment — license enforcement bypassed.
    /// `reason` describes which heuristic matched (for logs/dashboard).
    case freeDev(reason: String)

    /// Production build with no valid license. `reason` is the human-
    /// readable explanation: missing file, signature didn't verify,
    /// audience mismatch, etc. The SDK throws on this status in
    /// `validateAndAssert()`.
    case freeProd(reason: String)

    /// Had a valid license but `exp` is past. Surfaced separately so the
    /// developer/dashboard knows whose renewal to chase. Throws in
    /// `validateAndAssert()`.
    case freeExpired(licensee: String, expiredAt: Int64)

    /// True when the status represents a paid / unwatermarked tier.
    public var isPaid: Bool {
        switch self {
        case .commercial, .trial: return true
        case .freeDev, .freeProd, .freeExpired: return false
        }
    }

    /// Stable string identifier per case — useful for logging and for
    /// matching the JS-side `status.kind` field 1:1.
    public var kind: String {
        switch self {
        case .commercial: return "commercial"
        case .trial: return "trial"
        case .freeDev: return "free-dev"
        case .freeProd: return "free-prod"
        case .freeExpired: return "free-expired"
        }
    }
}

/// JWT payload shape we issue. Conforms to `JWTPayload` so JWTKit can
/// decode it; the `verify(using:)` method is a no-op because we run our
/// own claim verification at the `LicenseValidator` level (so we can
/// produce specific free-prod reasons rather than generic JWT errors).
///
/// The wire field names use `aud` / `iss` etc. directly so the JSON is
/// identical to the JS-side payload.
public struct DvaiLicensePayload: Codable, Equatable {
    /// Standard JWT issuer. Must equal `"DVAI-Bridge"`.
    public let iss: String
    /// Standard subject — internal license id.
    public let sub: String
    /// Audience binding: exact strings OR `*.example.com` wildcard subdomain
    /// patterns OR `*` (any-domain). Matched against
    /// `Bundle.main.bundleIdentifier` at runtime.
    public let aud: [String]
    /// Tier the license grants. Only `commercial` / `trial` are valid
    /// here — `free*` is computed by the validator, never claimed.
    public let tier: String
    /// Which SDK platforms this license activates. Current runtime must
    /// be in this list for the license to apply.
    public let platforms: [String]
    /// Display name of the licensee, for audit logs and dashboards.
    public let licensee: String
    /// Standard JWT issued-at (seconds since Unix epoch).
    public let iat: Int64
    /// Standard JWT expiry (seconds since Unix epoch).
    public let exp: Int64

    public init(
        iss: String,
        sub: String,
        aud: [String],
        tier: String,
        platforms: [String],
        licensee: String,
        iat: Int64,
        exp: Int64
    ) {
        self.iss = iss
        self.sub = sub
        self.aud = aud
        self.tier = tier
        self.platforms = platforms
        self.licensee = licensee
        self.iat = iat
        self.exp = exp
    }
}

#if !COCOAPODS
extension DvaiLicensePayload: JWTPayload {
    /// JWTKit hook — we intentionally do NOT verify exp/aud here, because
    /// the validator wants specific failure reasons per claim. JWTKit's
    /// `verify(_:as:)` will still verify the signature; the claim
    /// verification happens in `LicenseValidator.verifyToken`.
    public func verify(using algorithm: some JWTAlgorithm) async throws {
        // No-op: see comment above.
    }
}
#endif

/// Thrown by `LicenseValidator.validateAndAssert()` (and propagated from
/// `DVAIBridge.start(...)`) when an SDK consumer attempts to run the
/// library in a production / release context without a valid commercial
/// or trial license.
///
/// The error message is intentionally verbose: it tells the developer
/// exactly which check failed, how to resolve it, where to put the
/// license file, and how to bypass for local development. This is the
/// front line of the BSL 1.1 commercial enforcement story — surface it
/// clearly enough that a developer can unblock themselves without a
/// support ticket.
///
/// The `status` field carries the underlying `LicenseStatus` so
/// programmatic callers can dispatch on `err.status.kind` if they
/// want to handle expired vs. missing differently.
public struct LicenseRequiredError: Error, LocalizedError, Sendable {
    public let message: String
    public let status: LicenseStatus

    public init(message: String, status: LicenseStatus) {
        self.message = message
        self.status = status
    }

    public var errorDescription: String? { message }
}
