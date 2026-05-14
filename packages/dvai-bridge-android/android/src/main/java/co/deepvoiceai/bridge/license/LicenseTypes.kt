package co.deepvoiceai.bridge.license

/**
 * Type surface for the DVAI-Bridge offline JWT license system.
 *
 * Kotlin port of `packages/dvai-bridge-core/src/license/types.ts`. The
 * sealed [LicenseStatus] hierarchy mirrors the JS discriminated-union;
 * each case carries the same fields. Android-native consumers dispatch
 * on `when (status)` exhaustively, matching the JS `switch(status.kind)`.
 *
 * The whole license flow is deliberately small:
 *   1. A signed JWT (produced server-side by your license generator) is
 *      either dropped at a platform-default path, pointed at via the
 *      [co.deepvoiceai.bridge.StartOptions.licenseKeyPath] config option,
 *      or pasted directly into [co.deepvoiceai.bridge.StartOptions.licenseToken].
 *   2. The SDK reads it, verifies the ECDSA P-256 signature against the
 *      key registry in [DvaiPublicKeys], and checks four runtime claims:
 *      - signature must verify against a known kid
 *      - `exp` must be in the future
 *      - `aud` must include the current audience (package name)
 *      - `platforms` must include "android"
 *   3. The outcome is summarised in a [LicenseStatus] value that the
 *      rest of the SDK can dispatch on.
 *
 * Nothing in this file makes network calls. The entire flow is offline.
 */

/** Platform identifiers the SDK recognises in license `platforms` claims. */
enum class DvaiPlatform(val wire: String) {
    WEB("web"),
    NODE("node"),
    IOS("ios"),
    ANDROID("android"),
    DOTNET("dotnet"),
    FLUTTER("flutter"),
    REACT_NATIVE("react-native"),
    CAPACITOR("capacitor");

    companion object {
        fun fromWire(s: String): DvaiPlatform? = values().firstOrNull { it.wire == s }
    }
}

/**
 * Payload shape we issue (subset; extra claims tolerated). Mirrors the
 * JS-side `DvaiLicensePayload`.
 *
 * @property iss        Standard JWT issuer claim. Must be `"DVAI-Bridge"`.
 * @property sub        Standard subject — internal license id. Surfaced in audit logs.
 * @property aud        Audience binding — list of domains and/or bundle ids permitted
 *                      to activate this license. Each entry is either an exact string
 *                      match (e.g. `"com.acme.app"`) or a wildcard subdomain
 *                      pattern (e.g. `"*.acme.com"` matches both `acme.com` and
 *                      `app.acme.com`), or `"*"` for any-audience licenses.
 * @property tier       Tier the license grants. `"commercial"` and `"trial"` are
 *                      the live tiers; the validator never produces `"free-*"` here
 *                      (those are computed at validation time).
 * @property platforms  Which DVAI-Bridge SDK platforms this license activates.
 *                      The current runtime platform must appear here for the
 *                      license to apply.
 * @property licensee   Display name of the licensee, for audit logs + user-facing messaging.
 * @property iat        Standard JWT issued-at (seconds since Unix epoch).
 * @property exp        Standard JWT expiry (seconds since Unix epoch).
 */
data class DvaiLicensePayload(
    val iss: String,
    val sub: String,
    val aud: List<String>,
    val tier: String, // "commercial" | "trial"
    val platforms: List<String>,
    val licensee: String,
    val iat: Long,
    val exp: Long,
)

/**
 * Result of license validation. Sealed class so the consumer's decision
 * tree is exhaustive (`Commercial` or `Trial` → premium; everything else
 * → free).
 *
 * Note: on Android the validator NEVER produces a [FreeProd] status that
 * the SDK then runs in free tier — production Android without a license
 * throws via [LicenseRequiredError]. The status case exists so that
 * `validate()` (the non-throwing variant) can describe the failure for
 * host-app dashboards / logging, but [LicenseValidator.validateAndAssert]
 * (called from `DVAIBridge.start`) converts it to a throw.
 */
sealed class LicenseStatus {
    /** Paid commercial license — premium tier. */
    data class Commercial(
        val licensee: String,
        val expiresAt: Long,
        val platform: DvaiPlatform,
        val audienceMatched: String,
    ) : LicenseStatus()

    /** Paid trial license — premium tier, time-limited. */
    data class Trial(
        val licensee: String,
        val expiresAt: Long,
        val platform: DvaiPlatform,
        val audienceMatched: String,
    ) : LicenseStatus()

    /**
     * Debug build / dev-mode bypass. License enforcement skipped.
     * @property reason Why dev mode was detected (for logging / dashboard surfacing).
     */
    data class FreeDev(val reason: String) : LicenseStatus()

    /**
     * Production deploy with no valid license. On Android,
     * `validateAndAssert()` throws [LicenseRequiredError] for this case
     * rather than allowing free-tier operation — unlike the JS SDK which
     * runs with a watermark in free-prod.
     *
     * @property reason Specific failure mode (no token, signature failed,
     *                  audience mismatch, etc.) — verbose by design so the
     *                  developer can self-debug without a support ticket.
     */
    data class FreeProd(val reason: String) : LicenseStatus()

    /**
     * Had a valid license but `exp` is in the past. On Android,
     * `validateAndAssert()` throws [LicenseRequiredError] for this case.
     */
    data class FreeExpired(
        val licensee: String,
        val expiredAt: Long,
    ) : LicenseStatus()
}

/** Returns true iff `status` represents a paid / unwatermarked tier. */
fun isPaidTier(status: LicenseStatus): Boolean =
    status is LicenseStatus.Commercial || status is LicenseStatus.Trial

/**
 * Thrown by [LicenseValidator.validateAndAssert] (and propagated from
 * `DVAIBridge.start(...)`) when an SDK consumer attempts to run the
 * library in a production / release context without a valid commercial
 * or trial license.
 *
 * The error message is intentionally verbose: it tells the developer
 * exactly which check failed (missing file, expired, audience mismatch,
 * etc.), how to resolve it, and where to put the license file once
 * they have one. This is the front line of the BSL 1.1 commercial
 * enforcement story — surface it clearly enough that a developer can
 * unblock themselves without a support ticket.
 *
 * The `status` field carries the underlying [LicenseStatus] so
 * programmatic callers can dispatch on `err.status` if they want to
 * handle "expired" differently from "missing".
 */
class LicenseRequiredError(
    message: String,
    /** The underlying validator status that triggered the throw. */
    val status: LicenseStatus,
) : Exception(message)
