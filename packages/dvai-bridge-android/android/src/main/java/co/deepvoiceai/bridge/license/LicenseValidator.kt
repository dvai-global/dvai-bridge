package co.deepvoiceai.bridge.license

import android.content.Context
import android.util.Base64
import com.nimbusds.jose.JOSEException
import com.nimbusds.jose.JWSAlgorithm
import com.nimbusds.jose.crypto.ECDSAVerifier
import com.nimbusds.jose.jwk.Curve
import com.nimbusds.jose.jwk.ECKey
import com.nimbusds.jose.util.Base64URL
import com.nimbusds.jwt.SignedJWT
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.text.ParseException
import java.util.Date

/**
 * DVAI-Bridge license validator — offline JWT verification.
 *
 * Kotlin port of `packages/dvai-bridge-core/src/license/LicenseValidator.ts`.
 * Verifies a JWT (header + payload + ECDSA P-256 signature) using
 * `nimbus-jose-jwt`. The SDK ships only with public keys (see
 * [DvaiPublicKeys]) and cannot itself produce valid licenses — so
 * reverse-engineering the bundled APK gains nothing.
 *
 * Network calls: zero. The whole flow is offline by design — there's
 * no "phone home" step, no license server polling, no DRM beacon.
 *
 * Android divergence from the JS validator: in production (non-DEBUG)
 * Android builds, both [validateAndAssert] and the SDK's `start(...)`
 * THROW [LicenseRequiredError] rather than falling back to a watermarked
 * free-tier. This matches the iOS validator and the BSL 1.1 commercial
 * enforcement story for native mobile distributions.
 *
 * @param context              Application context (typically
 *                             `applicationContext`). Required for audience
 *                             detection (package name) and discovery
 *                             (assets, raw resources, internal storage).
 * @param token                Pre-loaded JWT string. If non-null, skips all
 *                             auto-discovery.
 * @param path                 Explicit license file path. Overrides
 *                             auto-discovery if non-null.
 * @param hostBuildConfigDebug The host app's `BuildConfig.DEBUG` value. Pass
 *                             this from `Application.onCreate()` so the
 *                             validator can bypass enforcement on debug builds.
 *                             Falls back to `ApplicationInfo.FLAG_DEBUGGABLE`
 *                             if null.
 * @param publicKeys           Override for the public-key registry. Defaults
 *                             to [DvaiPublicKeys.REGISTRY]. Tests inject
 *                             their own keypair so they can sign + verify
 *                             against a deterministic key without polluting
 *                             the production registry.
 * @param allowPlaceholderKey  If true, accept tokens signed under
 *                             [PLACEHOLDER_KID]. Off by default — a real
 *                             production build must replace the placeholder
 *                             with a generated key. Tests set this to true.
 */
class LicenseValidator(
    private val context: Context,
    private val token: String? = null,
    private val path: String? = null,
    private val hostBuildConfigDebug: Boolean? = null,
    private val publicKeys: Map<String, DvaiPublicKeyJwk> = DvaiPublicKeys.REGISTRY,
    private val allowPlaceholderKey: Boolean = false,
) {
    /**
     * Validate WITHOUT throwing. Returns a [LicenseStatus] describing what
     * the validator determined; never throws on missing / invalid /
     * expired licenses. Useful for host-app dashboards that want to
     * display the licensee / expiry / fallback reason without halting
     * SDK startup, and for tests.
     *
     * Idempotent; safe to call multiple times.
     */
    suspend fun validate(): LicenseStatus = withContext(Dispatchers.IO) {
        // 1. Dev-mode bypass — license required only in production.
        val dev = detectDevMode(context, hostBuildConfigDebug)
        if (dev.isDev) {
            return@withContext LicenseStatus.FreeDev(dev.reason)
        }

        // 2. Discover the token. Returns null when no license source is
        //    configured AND auto-discovery fails.
        val discovered = discoverLicenseToken(
            context,
            LicenseDiscoveryOptions(token = token, path = path),
        )
        if (discovered == null) {
            return@withContext LicenseStatus.FreeProd(
                "no license token found; checked config.licenseToken, " +
                    "config.licenseKeyPath, DVAI_LICENSE_PATH env, " +
                    "DVAI_LICENSE_TOKEN env, assets/$DEFAULT_LICENSE_FILENAME, " +
                    "res/raw/$DEFAULT_LICENSE_RAW_RESOURCE_NAME, " +
                    "and filesDir/$DEFAULT_LICENSE_FILENAME",
            )
        }

        // 3. Verify signature + claims with nimbus-jose-jwt.
        verifyToken(discovered.token, detectPlatform(), detectAudience(context))
    }

    /**
     * Strict validation entry point used by the SDK at startup. Returns
     * [LicenseStatus] on success ([LicenseStatus.Commercial],
     * [LicenseStatus.Trial], [LicenseStatus.FreeDev]) and THROWS
     * [LicenseRequiredError] on [LicenseStatus.FreeProd] /
     * [LicenseStatus.FreeExpired].
     *
     * This is the BSL 1.1 enforcement point: in production / release
     * builds (any non-dev-mode environment), the SDK refuses to operate
     * without a valid commercial or trial license. Developers running on
     * debug builds / `BuildConfig.DEBUG=true` / explicit DVAI_FORCE_DEV
     * are unaffected — those return a [LicenseStatus.FreeDev] status and
     * the SDK proceeds normally.
     *
     * Use [validate] instead when you want to inspect the status without
     * halting startup (host-app dashboards, test fixtures).
     */
    suspend fun validateAndAssert(): LicenseStatus {
        val status = validate()
        when (status) {
            is LicenseStatus.FreeProd ->
                throw LicenseRequiredError(buildRequiredErrorMessage(status), status)
            is LicenseStatus.FreeExpired ->
                throw LicenseRequiredError(buildRequiredErrorMessage(status), status)
            else -> return status
        }
    }

    private fun verifyToken(
        token: String,
        platform: DvaiPlatform,
        runtimeAudience: String?,
    ): LicenseStatus {
        // Parse the JWT structure first so we can read the header to pick
        // the right public key. We could let nimbus iterate but specifying
        // the key up-front gives clearer error messages on misses.
        val parts = token.split(".")
        if (parts.size != 3 || parts[0].isEmpty()) {
            return LicenseStatus.FreeProd(
                "license token is not a well-formed JWT (need 3 segments)",
            )
        }

        val headerJson: JSONObject = try {
            JSONObject(base64UrlDecodeUtf8(parts[0]))
        } catch (e: Throwable) {
            return LicenseStatus.FreeProd(
                "license token header is not parseable JSON: ${e.message ?: e.javaClass.simpleName}",
            )
        }

        val alg = headerJson.optString("alg", "")
        if (alg != "ES256") {
            // Refuse `alg: none` and any non-ES256 algorithm. Critical
            // defense against the classic JWT algorithm-confusion vulnerability.
            return LicenseStatus.FreeProd(
                "license token uses unsupported alg \"${alg.ifEmpty { "(missing)" }}\", expected ES256",
            )
        }

        val kid = headerJson.optString("kid", "")
        if (kid.isEmpty()) {
            return LicenseStatus.FreeProd(
                "license token header missing kid; cannot select verification key",
            )
        }

        val jwk = publicKeys[kid]
            ?: return LicenseStatus.FreeProd(
                "license token kid \"$kid\" is not in the SDK's public-key " +
                    "registry; either the key was rotated and you're on an old SDK, " +
                    "or the token was signed with a key we don't recognise",
            )

        if (kid == PLACEHOLDER_KID && !allowPlaceholderKey) {
            return LicenseStatus.FreeProd(
                "license token signed with the placeholder key (kid \"$PLACEHOLDER_KID\"); " +
                    "replace the placeholder in PublicKeys.kt with a real key generated " +
                    "via scripts/license/generate-keypair.mjs before issuing real licenses",
            )
        }

        // Parse the JWT structure (header / payload / signature) with nimbus.
        val signed: SignedJWT = try {
            SignedJWT.parse(token)
        } catch (e: ParseException) {
            return LicenseStatus.FreeProd(
                "license token verification failed: ${e.message ?: "parse error"}",
            )
        }

        // Verify signature. Build the public ECKey from the JWK coordinate
        // strings (x / y). nimbus expects `Base64URL`-wrapped strings — they're
        // already base64url-encoded in the JWK, so we just rehydrate.
        val ecKey: ECKey = try {
            ECKey.Builder(Curve.P_256, Base64URL(jwk.x), Base64URL(jwk.y))
                .keyID(jwk.kid ?: kid)
                .build()
        } catch (e: Throwable) {
            return LicenseStatus.FreeProd(
                "license public-key entry is malformed: ${e.message ?: e.javaClass.simpleName}",
            )
        }

        try {
            if (signed.header.algorithm != JWSAlgorithm.ES256) {
                // Defense-in-depth — we already checked the header above,
                // but nimbus might surface its own opinion about the alg.
                return LicenseStatus.FreeProd(
                    "license token uses unsupported alg \"${signed.header.algorithm}\", expected ES256",
                )
            }
            val verifier = ECDSAVerifier(ecKey)
            if (!signed.verify(verifier)) {
                return LicenseStatus.FreeProd(
                    "license token signature did not verify against kid \"$kid\"; " +
                        "the token may have been tampered with or was signed by a different key",
                )
            }
        } catch (e: JOSEException) {
            return LicenseStatus.FreeProd(
                "license token verification failed: ${e.message ?: e.javaClass.simpleName}",
            )
        } catch (e: Throwable) {
            return LicenseStatus.FreeProd(
                "license token verification failed: ${e.message ?: e.javaClass.simpleName}",
            )
        }

        // Coerce + validate the payload shape ourselves. nimbus' claim
        // set is loose-typed JSON; we want strict checks with specific
        // free-prod reasons.
        val claims = signed.jwtClaimsSet
        val payload = parsePayload(claims.toJSONObject())
            ?: return LicenseStatus.FreeProd(
                "license token payload missing required DVAI fields (tier/platforms/aud/licensee)",
            )

        // Issuer check.
        if (payload.iss != "DVAI-Bridge") {
            return LicenseStatus.FreeProd(
                "license token claim \"iss\" failed: expected \"DVAI-Bridge\", got \"${payload.iss}\"",
            )
        }

        // Expiry check. Surface "free-expired" specifically so the developer
        // knows whose renewal to chase.
        val nowSec = System.currentTimeMillis() / 1000
        if (payload.exp <= nowSec) {
            return LicenseStatus.FreeExpired(
                licensee = payload.licensee,
                expiredAt = payload.exp,
            )
        }

        // Platform check.
        if (!payload.platforms.contains(platform.wire)) {
            return LicenseStatus.FreeProd(
                "license token does not authorise platform \"${platform.wire}\"; " +
                    "the token covers [${payload.platforms.joinToString(", ")}]",
            )
        }

        // Audience check.
        val matched = matchAudience(runtimeAudience, payload.aud)
            ?: return LicenseStatus.FreeProd(
                "license token's audience entries [${payload.aud.joinToString(", ")}] " +
                    "do not match the current runtime audience \"${runtimeAudience ?: "(none)"}\"" +
                    if (runtimeAudience == null) {
                        " — set DVAI_AUDIENCE in your environment, or use a \"*\" aud entry for any-domain licenses"
                    } else {
                        ""
                    },
            )

        return when (payload.tier) {
            "commercial" -> LicenseStatus.Commercial(
                licensee = payload.licensee,
                expiresAt = payload.exp,
                platform = platform,
                audienceMatched = matched,
            )
            "trial" -> LicenseStatus.Trial(
                licensee = payload.licensee,
                expiresAt = payload.exp,
                platform = platform,
                audienceMatched = matched,
            )
            else -> LicenseStatus.FreeProd(
                "license token payload missing required DVAI fields (tier/platforms/aud/licensee)",
            )
        }
    }
}

/* -------------------------------------------------------------------------- */
/* Helpers                                                                    */
/* -------------------------------------------------------------------------- */

/**
 * Parse the JWT payload into a [DvaiLicensePayload], or return null if any
 * required field is missing/malformed. Mirrors `isLicensePayload` on the JS side.
 */
private fun parsePayload(claims: Map<String, Any?>): DvaiLicensePayload? {
    val iss = claims["iss"] as? String ?: return null
    val sub = claims["sub"] as? String ?: return null
    val tier = claims["tier"] as? String ?: return null
    if (tier != "commercial" && tier != "trial") return null
    val licensee = claims["licensee"] as? String ?: return null

    // `aud` can be either a JSON array (the canonical form) or a single
    // string (nimbus sometimes single-unwraps single-element audiences).
    // We coerce both into a List<String>.
    val audRaw = claims["aud"]
    val aud: List<String> = when (audRaw) {
        is List<*> -> audRaw.filterIsInstance<String>().also {
            if (it.size != audRaw.size) return null
        }
        is String -> listOf(audRaw)
        else -> return null
    }

    val platformsRaw = claims["platforms"] as? List<*> ?: return null
    val platforms = platformsRaw.filterIsInstance<String>()
    if (platforms.size != platformsRaw.size) return null

    // `iat` / `exp` are seconds-since-epoch integers in our JWTs, but
    // nimbus' parser may surface them as Date or Number. Coerce both.
    val iat = coerceEpochSeconds(claims["iat"]) ?: return null
    val exp = coerceEpochSeconds(claims["exp"]) ?: return null

    return DvaiLicensePayload(
        iss = iss,
        sub = sub,
        aud = aud,
        tier = tier,
        platforms = platforms,
        licensee = licensee,
        iat = iat,
        exp = exp,
    )
}

private fun coerceEpochSeconds(v: Any?): Long? = when (v) {
    is Number -> v.toLong()
    is Date -> v.time / 1000
    else -> null
}

/** Decode base64url-encoded JSON header to a UTF-8 string. */
private fun base64UrlDecodeUtf8(s: String): String {
    val bytes = Base64.decode(s, Base64.URL_SAFE or Base64.NO_WRAP)
    return String(bytes, Charsets.UTF_8)
}

/**
 * Build the developer-facing error message for [LicenseRequiredError].
 * Intentionally verbose — mirrors the JS side's multi-line format with
 * Android-specific resolution paths.
 */
internal fun buildRequiredErrorMessage(status: LicenseStatus): String {
    val header =
        "\n" +
            "DVAI-Bridge Commercial License Required\n" +
            "=======================================\n"

    val reason = when (status) {
        is LicenseStatus.FreeExpired ->
            "License for \"${status.licensee}\" expired at ${Date(status.expiredAt * 1000)}."
        is LicenseStatus.FreeProd -> status.reason
        else -> "(unknown status)"
    }

    val remediation =
        "\n" +
            "This SDK is licensed under BSL 1.1 and requires a valid commercial\n" +
            "or trial license to run in production / release builds.\n" +
            "\n" +
            "To resolve:\n" +
            "  1. Obtain a license at https://deepvoiceai.com/dvai-bridge/license\n" +
            "  2. Place the file at one of these locations (any will work):\n" +
            "       - assets/dvai-license.jwt           (bundled in the APK; auto-discovered)\n" +
            "       - res/raw/dvai_license              (bundled raw resource; auto-discovered)\n" +
            "       - filesDir/dvai-license.jwt         (internal storage; auto-discovered)\n" +
            "       - the path you pass as StartOptions.licenseKeyPath\n" +
            "       - the path in \$DVAI_LICENSE_PATH\n" +
            "       - inline JWT in StartOptions.licenseToken or \$DVAI_LICENSE_TOKEN\n" +
            "  3. Re-run.\n" +
            "\n" +
            "Developing locally? The SDK auto-detects dev mode on:\n" +
            "  - BuildConfig.DEBUG=true (pass hostBuildConfigDebug through StartOptions)\n" +
            "  - apps installed with ApplicationInfo.FLAG_DEBUGGABLE\n" +
            "  - DVAI_FORCE_DEV=1 environment variable (explicit override)\n" +
            "Any of these silences this error and lets the SDK run without a\n" +
            "license.\n"

    return header + "\n" + reason + "\n" + remediation
}
