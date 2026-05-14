package co.deepvoiceai.bridge.license

/**
 * Public-key registry for DVAI-Bridge license JWT verification.
 *
 * Kotlin port of `packages/dvai-bridge-core/src/license/publicKeys.ts` — semantics
 * and registry contents are 1:1 with the JS side. The same JWT format and the
 * same kids work across the JS, iOS, and Android validators.
 *
 * Each entry is keyed by `kid` (key id, written by the license generator
 * into the JWT header). The SDK looks up the matching entry by kid when
 * verifying a license token. Multiple entries can coexist so that key
 * rotation is non-disruptive: ship the new key in a release alongside
 * the old, leave the old in place for ~12 months while previously-
 * issued licenses naturally expire or get re-issued, then prune.
 *
 * THE PRIVATE KEY DOES NOT LIVE HERE. It belongs in your secrets
 * manager (1Password / AWS Secrets Manager / Vault), accessible only
 * to the license-generator service that produces signed JWTs. The
 * mathematics of ECDSA P-256 guarantee that a holder of the public
 * key alone cannot forge a signature.
 */

/** ES256 (P-256 ECDSA) public key in JWK form. */
data class DvaiPublicKeyJwk(
    val kty: String = "EC",
    val crv: String = "P-256",
    val x: String,
    val y: String,
    val alg: String? = "ES256",
    val use: String? = "sig",
    val kid: String? = null,
)

/**
 * `kid` reserved for the placeholder key. The validator refuses to
 * accept tokens signed with this kid unless the caller explicitly opts
 * in (`allowPlaceholderKey = true` passed to the validator constructor,
 * used by tests and by the sample license printed by the keypair-
 * generator script).
 */
const val PLACEHOLDER_KID: String = "placeholder-do-not-ship"

/**
 * Registry mapping `kid` → public key JWK.
 *
 * The entry below is a **placeholder** — it is a published, well-known
 * test keypair and DOES NOT verify any real production license. Before
 * shipping licenses to customers, replace it with the output of
 * `scripts/license/generate-keypair.mjs`. The SDK refuses to validate
 * licenses against the placeholder kid unless `allowPlaceholderKey` is
 * set (test-only escape hatch).
 *
 * To add a new key for rotation, add a second entry keyed by the new
 * `kid`; old licenses keep verifying against the old key, new licenses
 * (issued by the generator that knows the new private key) verify
 * against the new entry.
 */
object DvaiPublicKeys {
    /** Production registry. Mirrors `DVAI_PUBLIC_KEYS` on the JS side. */
    val REGISTRY: Map<String, DvaiPublicKeyJwk> = mapOf(
        PLACEHOLDER_KID to DvaiPublicKeyJwk(
            kty = "EC",
            crv = "P-256",
            x = "MKBCTNIcKUSDii11ySs3526iDZ8AiTo7Tu6KPAqv7D4",
            y = "4Etl6SRW2YiLUrN5vfvVHuhp7x8PxltmWWlbbM4IFyM",
            alg = "ES256",
            use = "sig",
            kid = PLACEHOLDER_KID,
        ),
    )
}
