/*
 * Public-key registry for DVAI-Bridge license JWT verification on iOS.
 *
 * Mirrors `packages/dvai-bridge-core/src/license/publicKeys.ts`.
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
 *
 * To populate this registry:
 *   1. Run `node scripts/license/generate-keypair.mjs` (see that
 *      script's comment for full instructions)
 *   2. Paste the printed PUBLIC key JWK as an entry below — and into
 *      the matching `publicKeys.ts` for the JS-side validator
 *   3. Move the printed PRIVATE key into your secrets store
 *   4. Wire your license-generator backend to use the private key
 */
import Foundation

/// ES256 (ECDSA P-256) public key in JWK form. The shape matches the
/// IANA JWK spec — x/y are base64url-encoded 32-byte big-endian
/// coordinates. Same fields as the JS-side `DvaiPublicKeyJwk`.
public struct DvaiPublicKeyJwk: Sendable, Equatable {
    /// Always `"EC"` for ECDSA keys.
    public let kty: String
    /// Always `"P-256"` for ES256.
    public let crv: String
    /// Base64url-encoded X coordinate (32 bytes).
    public let x: String
    /// Base64url-encoded Y coordinate (32 bytes).
    public let y: String
    /// Algorithm hint. Should be `"ES256"` for our keys.
    public let alg: String?
    /// Key use hint. Should be `"sig"`.
    public let use: String?
    /// Key identifier — must match the JWT header `kid` to be selected.
    public let kid: String?

    public init(
        kty: String = "EC",
        crv: String = "P-256",
        x: String,
        y: String,
        alg: String? = "ES256",
        use: String? = "sig",
        kid: String? = nil
    ) {
        self.kty = kty
        self.crv = crv
        self.x = x
        self.y = y
        self.alg = alg
        self.use = use
        self.kid = kid
    }
}

/// `kid` reserved for the placeholder key below. The validator refuses
/// to accept tokens signed with this kid unless the caller explicitly
/// opts in (`allowPlaceholderKey: true` passed to the validator
/// constructor). Used by tests and by the sample license printed by
/// `generate-keypair.mjs`.
public let DVAI_PLACEHOLDER_KID = "placeholder-do-not-ship"

/// Registry mapping `kid` → public key JWK.
///
/// WARNING: The entry below is a **placeholder** — it is a published,
/// well-known test keypair and DOES NOT verify any real production
/// license. Before shipping licenses to customers, replace it with the
/// output of `scripts/license/generate-keypair.mjs`. The SDK refuses
/// to validate licenses against the placeholder kid
/// `"placeholder-do-not-ship"` unless `allowPlaceholderKey: true` is
/// passed to the validator (test-only escape hatch).
///
/// Adding a new key for rotation:
///
///     public let DVAI_PUBLIC_KEYS: [String: DvaiPublicKeyJwk] = [
///         "2026-05": DvaiPublicKeyJwk(x: "...", y: "...", kid: "2026-05"),
///         "2027-01": DvaiPublicKeyJwk(x: "...", y: "...", kid: "2027-01"),
///     ]
public let DVAI_PUBLIC_KEYS: [String: DvaiPublicKeyJwk] = [
    // PLACEHOLDER — replace with the output of scripts/license/generate-keypair.mjs
    // before issuing any real licenses.
    DVAI_PLACEHOLDER_KID: DvaiPublicKeyJwk(
        x: "MKBCTNIcKUSDii11ySs3526iDZ8AiTo7Tu6KPAqv7D4",
        y: "4Etl6SRW2YiLUrN5vfvVHuhp7x8PxltmWWlbbM4IFyM",
        alg: "ES256",
        use: "sig",
        kid: DVAI_PLACEHOLDER_KID
    ),
]
