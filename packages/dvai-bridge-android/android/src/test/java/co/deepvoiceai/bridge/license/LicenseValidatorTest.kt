package co.deepvoiceai.bridge.license

import android.content.Context
import com.nimbusds.jose.JOSEObjectType
import com.nimbusds.jose.JWSAlgorithm
import com.nimbusds.jose.JWSHeader
import com.nimbusds.jose.crypto.ECDSASigner
import com.nimbusds.jose.jwk.Curve
import com.nimbusds.jose.jwk.ECKey
import com.nimbusds.jose.jwk.gen.ECKeyGenerator
import com.nimbusds.jwt.JWTClaimsSet
import com.nimbusds.jwt.SignedJWT
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.util.Date
import java.util.UUID

/**
 * Tests for the JWT-based license validator on Android.
 *
 * Direct port of `packages/dvai-bridge-core/src/__tests__/license.test.ts` —
 * same scenarios, same expectations, same coverage of failure modes.
 *
 * Two APIs are tested:
 *   - `validate()`           — never throws; returns `LicenseStatus`.
 *   - `validateAndAssert()`  — throws `LicenseRequiredError` for
 *                              `FreeProd` / `FreeExpired`. This is the
 *                              BSL 1.1 enforcement entry point used by
 *                              `DVAIBridge.start()`.
 *
 * Runs under Robolectric so `android.content.Context` (audience detection,
 * discovery) and `android.util.Base64` (JWT header decode) are available
 * without an emulator. The test keypair is generated once per class so we
 * don't re-derive on every case.
 *
 * Every test that exercises a non-dev-mode code path passes
 * `hostBuildConfigDebug = false` explicitly via [prodValidator]. Robolectric
 * applications default to `ApplicationInfo.FLAG_DEBUGGABLE` set, which
 * would otherwise collapse every test into a `FreeDev` bypass.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class LicenseValidatorTest {

    companion object {
        private const val TEST_KID = "test-kid-2026"
        private lateinit var ecJwk: ECKey
        private lateinit var publicKeys: Map<String, DvaiPublicKeyJwk>

        @BeforeClass
        @JvmStatic
        fun generateTestKeyPair() {
            // ES256 / P-256 keypair, mirrors the JS test setup.
            ecJwk = ECKeyGenerator(Curve.P_256)
                .keyID(TEST_KID)
                .generate()
            val pub = ecJwk.toPublicJWK()
            publicKeys = mapOf(
                TEST_KID to DvaiPublicKeyJwk(
                    kty = "EC",
                    crv = "P-256",
                    x = pub.x.toString(),
                    y = pub.y.toString(),
                    alg = "ES256",
                    use = "sig",
                    kid = TEST_KID,
                ),
            )
        }
    }

    private lateinit var context: Context

    @Before
    fun setup() {
        context = RuntimeEnvironment.getApplication()
    }

    /**
     * Build a [LicenseValidator] with production-mode defaults so tests
     * exercise the license-required branches. Robolectric defaults
     * `ApplicationInfo.FLAG_DEBUGGABLE` to set, which would otherwise
     * collapse every test into a `FreeDev` bypass; pass
     * `hostBuildConfigDebug = false` explicitly to override.
     *
     * Dev-mode tests construct [LicenseValidator] directly with
     * `hostBuildConfigDebug = true`.
     */
    private fun prodValidator(
        token: String? = null,
        path: String? = null,
        registry: Map<String, DvaiPublicKeyJwk> = publicKeys,
        allowPlaceholderKey: Boolean = false,
    ): LicenseValidator = LicenseValidator(
        context = context,
        token = token,
        path = path,
        hostBuildConfigDebug = false,
        publicKeys = registry,
        allowPlaceholderKey = allowPlaceholderKey,
    )

    /** Mint a license JWT for tests. Mirrors `mintLicense` in the JS suite. */
    private fun mintLicense(
        aud: List<String> = listOf("*"),
        platforms: List<String> = listOf("node", "web", "ios", "android"),
        tier: String = "commercial",
        licensee: String = "Test Co",
        expSecondsFromNow: Long = 30L * 24 * 3600,
        absoluteExpSeconds: Long? = null,
        iss: String = "DVAI-Bridge",
        kid: String = TEST_KID,
        signWith: ECKey = ecJwk,
    ): String {
        val nowSec = System.currentTimeMillis() / 1000
        val exp = absoluteExpSeconds ?: (nowSec + expSecondsFromNow)
        val claims = JWTClaimsSet.Builder()
            .issuer(iss)
            .subject("test-license")
            .audience(aud)
            .issueTime(Date(nowSec * 1000))
            .expirationTime(Date(exp * 1000))
            .claim("tier", tier)
            .claim("licensee", licensee)
            .claim("platforms", platforms)
            .build()
        val header = JWSHeader.Builder(JWSAlgorithm.ES256)
            .type(JOSEObjectType.JWT)
            .keyID(kid)
            .build()
        val signed = SignedJWT(header, claims)
        signed.sign(ECDSASigner(signWith))
        return signed.serialize()
    }

    /* ------------------------------------------------------------------ */
    /* Happy path                                                          */
    /* ------------------------------------------------------------------ */

    @Test
    fun `accepts a well-formed commercial token and reports licensee + expiry`() = runTest {
        val token = mintLicense(
            aud = listOf(context.packageName),
            platforms = listOf("android"),
            licensee = "Acme Inc",
        )
        val status = prodValidator(token = token).validate()
        assertTrue("expected Commercial, got $status", status is LicenseStatus.Commercial)
        val c = status as LicenseStatus.Commercial
        assertEquals("Acme Inc", c.licensee)
        assertEquals(context.packageName, c.audienceMatched)
        assertEquals(DvaiPlatform.ANDROID, c.platform)
        assertTrue(c.expiresAt > System.currentTimeMillis() / 1000)
    }

    @Test
    fun `matches wildcard subdomain audience entries`() = runTest {
        // Android audience is the package name; package names use dot-
        // separated reverse-domain notation so the same `*.acme.com` rule
        // applies to `app.acme.com`-shaped package names.
        val pkg = context.packageName
        val parts = pkg.split(".")
        if (parts.size < 2) return@runTest // can't build a wildcard from a 1-segment package
        val suffix = parts.drop(1).joinToString(".")
        val token = mintLicense(
            aud = listOf("*.$suffix"),
            platforms = listOf("android"),
        )
        val status = prodValidator(token = token).validate()
        assertTrue("expected Commercial, got $status", status is LicenseStatus.Commercial)
        assertEquals("*.$suffix", (status as LicenseStatus.Commercial).audienceMatched)
    }

    @Test
    fun `matches star audience for any-domain trial licenses`() = runTest {
        val token = mintLicense(
            aud = listOf("*"),
            platforms = listOf("android"),
            tier = "trial",
        )
        val status = prodValidator(token = token).validate()
        assertTrue("expected Trial, got $status", status is LicenseStatus.Trial)
    }

    /* ------------------------------------------------------------------ */
    /* Failure modes — must collapse to a free-* status, never throw       */
    /* ------------------------------------------------------------------ */

    @Test
    fun `returns FreeProd when the token has been tampered with`() = runTest {
        val token = mintLicense(aud = listOf(context.packageName), platforms = listOf("android"))
        // Flip bytes in the payload segment to break the signature.
        val parts = token.split(".")
        val corrupted = "${parts[0]}.${parts[1].dropLast(2)}XX.${parts[2]}"
        val status = prodValidator(token = corrupted).validate()
        assertTrue("expected FreeProd, got $status", status is LicenseStatus.FreeProd)
        val reason = (status as LicenseStatus.FreeProd).reason.lowercase()
        assertTrue(
            "reason was: $reason",
            reason.contains("signature") || reason.contains("verification") ||
                reason.contains("parseable") || reason.contains("claim"),
        )
    }

    @Test
    fun `returns FreeExpired when exp is in the past`() = runTest {
        val pastSeconds = System.currentTimeMillis() / 1000 - 3600
        val token = mintLicense(
            aud = listOf(context.packageName),
            platforms = listOf("android"),
            licensee = "Expired Co",
            absoluteExpSeconds = pastSeconds,
        )
        val status = prodValidator(token = token).validate()
        assertTrue("expected FreeExpired, got $status", status is LicenseStatus.FreeExpired)
        val e = status as LicenseStatus.FreeExpired
        assertEquals("Expired Co", e.licensee)
        assertTrue(e.expiredAt < System.currentTimeMillis() / 1000)
    }

    @Test
    fun `returns FreeProd when audience does not match`() = runTest {
        val token = mintLicense(
            aud = listOf("com.different.app"),
            platforms = listOf("android"),
        )
        val status = prodValidator(token = token).validate()
        assertTrue("expected FreeProd, got $status", status is LicenseStatus.FreeProd)
        val reason = (status as LicenseStatus.FreeProd).reason
        assertTrue(reason, reason.contains("audience"))
        assertTrue(reason, reason.contains(context.packageName))
    }

    @Test
    fun `returns FreeProd when the runtime platform is not in the platforms claim`() = runTest {
        val token = mintLicense(
            aud = listOf(context.packageName),
            platforms = listOf("ios", "web"), // not android
        )
        val status = prodValidator(token = token).validate()
        assertTrue("expected FreeProd, got $status", status is LicenseStatus.FreeProd)
        val reason = (status as LicenseStatus.FreeProd).reason
        assertTrue(reason, reason.contains("platform"))
        assertTrue(reason, reason.contains("android"))
    }

    @Test
    fun `returns FreeProd when the kid in the header is not in the registry`() = runTest {
        val token = mintLicense(
            aud = listOf(context.packageName),
            platforms = listOf("android"),
            kid = "unknown-kid-2099",
        )
        val status = prodValidator(token = token).validate()
        assertTrue("expected FreeProd, got $status", status is LicenseStatus.FreeProd)
        val reason = (status as LicenseStatus.FreeProd).reason
        assertTrue(reason, reason.contains("unknown-kid-2099"))
        assertTrue(reason, reason.contains("registry"))
    }

    @Test
    fun `refuses the placeholder kid unless allowPlaceholderKey is set`() = runTest {
        // Mint with the placeholder kid (using OUR key, registered against
        // the placeholder kid in the local registry). Even though signature
        // verification would succeed, the validator must refuse the kid.
        val registryWithPlaceholderKid = mapOf(
            PLACEHOLDER_KID to publicKeys.values.first().copy(kid = PLACEHOLDER_KID),
        )
        val token = mintLicense(
            aud = listOf(context.packageName),
            platforms = listOf("android"),
            kid = PLACEHOLDER_KID,
        )
        val status = prodValidator(
            token = token,
            registry = registryWithPlaceholderKid,
        ).validate()
        assertTrue("expected FreeProd, got $status", status is LicenseStatus.FreeProd)
        assertTrue(
            (status as LicenseStatus.FreeProd).reason.contains("placeholder"),
        )
    }

    @Test
    fun `accepts the placeholder kid when allowPlaceholderKey is set`() = runTest {
        val registryWithPlaceholderKid = mapOf(
            PLACEHOLDER_KID to publicKeys.values.first().copy(kid = PLACEHOLDER_KID),
        )
        val token = mintLicense(
            aud = listOf(context.packageName),
            platforms = listOf("android"),
            kid = PLACEHOLDER_KID,
        )
        val status = prodValidator(
            token = token,
            registry = registryWithPlaceholderKid,
            allowPlaceholderKey = true,
        ).validate()
        assertTrue("expected Commercial, got $status", status is LicenseStatus.Commercial)
    }

    @Test
    fun `rejects alg=none tokens (algorithm-confusion defense)`() = runTest {
        // Build a hand-crafted alg=none token (header + payload + empty sig).
        val headerJson = """{"alg":"none","typ":"JWT"}"""
        val payloadJson = """{"iss":"DVAI-Bridge","sub":"x","aud":["${context.packageName}"],""" +
            """"tier":"commercial","platforms":["android"],"licensee":"Evil Co",""" +
            """"iat":${System.currentTimeMillis() / 1000},"exp":${System.currentTimeMillis() / 1000 + 3600}}"""
        val encoder = java.util.Base64.getUrlEncoder().withoutPadding()
        val header = encoder.encodeToString(headerJson.toByteArray())
        val payload = encoder.encodeToString(payloadJson.toByteArray())
        val noneToken = "$header.$payload."
        val status = prodValidator(token = noneToken).validate()
        assertTrue("expected FreeProd, got $status", status is LicenseStatus.FreeProd)
        assertTrue((status as LicenseStatus.FreeProd).reason.contains("ES256"))
    }

    @Test
    fun `returns FreeProd when token is malformed`() = runTest {
        val status = prodValidator(token = "not.a.valid.jwt").validate() // 4 segments
        assertTrue(status is LicenseStatus.FreeProd)
    }

    @Test
    fun `returns FreeProd when no token is provided AND no auto-discovery succeeds`() = runTest {
        // No token, no path — and the Robolectric app has no bundled asset
        // or raw resource named dvai-license.jwt, and filesDir is empty.
        val status = prodValidator().validate()
        assertTrue("expected FreeProd, got $status", status is LicenseStatus.FreeProd)
        assertTrue(
            (status as LicenseStatus.FreeProd).reason.contains("no license token found"),
        )
    }

    /* ------------------------------------------------------------------ */
    /* Dev mode bypass                                                     */
    /* ------------------------------------------------------------------ */

    @Test
    fun `returns FreeDev when hostBuildConfigDebug is true`() = runTest {
        val status = LicenseValidator(
            context = context,
            hostBuildConfigDebug = true,
            publicKeys = publicKeys,
        ).validate()
        assertTrue("expected FreeDev, got $status", status is LicenseStatus.FreeDev)
        assertTrue(
            (status as LicenseStatus.FreeDev).reason.contains("BuildConfig.DEBUG"),
        )
    }

    @Test
    fun `returns FreeDev when host omits BuildConfig and FLAG_DEBUGGABLE is set`() = runTest {
        // Robolectric's default ApplicationInfo carries FLAG_DEBUGGABLE — the
        // fallback heuristic should pick that up and return FreeDev when the
        // host didn't pass an explicit hostBuildConfigDebug.
        val status = LicenseValidator(
            context = context,
            // hostBuildConfigDebug intentionally null
            publicKeys = publicKeys,
        ).validate()
        assertTrue("expected FreeDev, got $status", status is LicenseStatus.FreeDev)
    }

    @Test
    fun `explicit hostBuildConfigDebug=false overrides FLAG_DEBUGGABLE`() = runTest {
        // Robolectric has FLAG_DEBUGGABLE set, but the host explicitly says
        // "not a debug build" — production mode wins, validator falls through
        // to discovery and (since no token is configured) returns FreeProd.
        val status = LicenseValidator(
            context = context,
            hostBuildConfigDebug = false,
            publicKeys = publicKeys,
        ).validate()
        assertTrue("expected FreeProd, got $status", status is LicenseStatus.FreeProd)
    }

    /* ------------------------------------------------------------------ */
    /* Token discovery                                                     */
    /* ------------------------------------------------------------------ */

    @Test
    fun `loads from an explicit path`() = runTest {
        val tmp = java.io.File.createTempFile("dvai-license-", ".jwt")
        val token = mintLicense(aud = listOf(context.packageName), platforms = listOf("android"))
        tmp.writeText(token)

        val status = prodValidator(path = tmp.absolutePath).validate()
        assertTrue("expected Commercial, got $status", status is LicenseStatus.Commercial)
        tmp.delete()
    }

    @Test
    fun `returns FreeProd when explicit path does not exist`() = runTest {
        val status = prodValidator(
            path = "/nonexistent/path/dvai-license.jwt-${UUID.randomUUID()}",
        ).validate()
        assertTrue("expected FreeProd, got $status", status is LicenseStatus.FreeProd)
    }

    @Test
    fun `loads from filesDir when no explicit source is given`() = runTest {
        val token = mintLicense(aud = listOf(context.packageName), platforms = listOf("android"))
        val file = java.io.File(context.filesDir, "dvai-license.jwt")
        try {
            file.writeText(token)
            val status = prodValidator().validate()
            assertTrue("expected Commercial, got $status", status is LicenseStatus.Commercial)
        } finally {
            file.delete()
        }
    }

    @Test
    fun `inline token wins over path when both are set`() = runTest {
        val inlineToken = mintLicense(
            aud = listOf(context.packageName),
            platforms = listOf("android"),
            licensee = "Inline Co",
        )
        val status = prodValidator(
            token = inlineToken,
            path = "/nonexistent/path/dvai-license.jwt",
        ).validate()
        assertTrue("expected Commercial, got $status", status is LicenseStatus.Commercial)
        assertEquals("Inline Co", (status as LicenseStatus.Commercial).licensee)
    }

    /* ------------------------------------------------------------------ */
    /* validateAndAssert — BSL 1.1 enforcement                             */
    /* ------------------------------------------------------------------ */

    @Test
    fun `validateAndAssert returns status without throwing for commercial licenses`() = runTest {
        val token = mintLicense(aud = listOf(context.packageName), platforms = listOf("android"))
        val status = prodValidator(token = token).validateAndAssert()
        assertTrue(status is LicenseStatus.Commercial)
    }

    @Test
    fun `validateAndAssert returns status without throwing for trial licenses`() = runTest {
        val token = mintLicense(
            aud = listOf(context.packageName),
            platforms = listOf("android"),
            tier = "trial",
        )
        val status = prodValidator(token = token).validateAndAssert()
        assertTrue(status is LicenseStatus.Trial)
    }

    @Test
    fun `validateAndAssert returns status without throwing for FreeDev`() = runTest {
        val status = LicenseValidator(
            context = context,
            hostBuildConfigDebug = true,
            publicKeys = publicKeys,
        ).validateAndAssert()
        assertTrue(status is LicenseStatus.FreeDev)
    }

    @Test
    fun `validateAndAssert throws LicenseRequiredError when no license found in production`() = runTest {
        try {
            prodValidator().validateAndAssert()
            fail("should have thrown")
        } catch (e: LicenseRequiredError) {
            assertTrue(e.status is LicenseStatus.FreeProd)
            assertTrue("message: ${e.message}", e.message!!.contains("Commercial License Required"))
            assertTrue("message: ${e.message}", e.message!!.contains("dvai-license.jwt"))
            assertTrue("message: ${e.message}", e.message!!.contains("DVAI_LICENSE_PATH"))
        }
    }

    @Test
    fun `validateAndAssert throws with status FreeExpired for expired tokens`() = runTest {
        val past = System.currentTimeMillis() / 1000 - 3600
        val token = mintLicense(
            aud = listOf(context.packageName),
            platforms = listOf("android"),
            licensee = "Expired Co",
            absoluteExpSeconds = past,
        )
        try {
            prodValidator(token = token).validateAndAssert()
            fail("should have thrown")
        } catch (e: LicenseRequiredError) {
            assertTrue(e.status is LicenseStatus.FreeExpired)
            assertTrue("message: ${e.message}", e.message!!.contains("Expired Co"))
        }
    }

    @Test
    fun `validateAndAssert throws for tampered tokens in production`() = runTest {
        val token = mintLicense(aud = listOf(context.packageName), platforms = listOf("android"))
        val parts = token.split(".")
        val corrupted = "${parts[0]}.${parts[1].dropLast(2)}XX.${parts[2]}"
        try {
            prodValidator(token = corrupted).validateAndAssert()
            fail("should have thrown")
        } catch (e: LicenseRequiredError) {
            assertNotNull(e.status)
        }
    }

    @Test
    fun `validateAndAssert throws for audience-mismatched tokens in production`() = runTest {
        val token = mintLicense(
            aud = listOf("com.different.app"),
            platforms = listOf("android"),
        )
        try {
            prodValidator(token = token).validateAndAssert()
            fail("should have thrown")
        } catch (_: LicenseRequiredError) {
            // expected
        }
    }

    @Test
    fun `validateAndAssert does NOT throw in dev mode even when license is invalid`() = runTest {
        val status = LicenseValidator(
            context = context,
            token = "not-even-a-jwt",
            hostBuildConfigDebug = true,
            publicKeys = publicKeys,
        ).validateAndAssert()
        assertTrue(status is LicenseStatus.FreeDev)
    }
}
