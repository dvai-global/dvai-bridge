/**
 * Public-key registry for DVAI-Bridge license JWT verification.
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
 *   2. Paste the printed PUBLIC key JWK as an entry below
 *   3. Move the printed PRIVATE key into your secrets store
 *   4. Wire your license-generator backend to use the private key
 */

/** ES256 (P-256 ECDSA) public key in JWK form. */
export interface DvaiPublicKeyJwk {
  kty: "EC";
  crv: "P-256";
  x: string;
  y: string;
  alg?: "ES256";
  use?: "sig";
  kid?: string;
}

/**
 * Registry mapping `kid` → public key JWK.
 *
 * ⚠️ The entry below is a **placeholder** — it is a published, well-known
 * test keypair and DOES NOT verify any real production license. Before
 * shipping licenses to customers, replace it with the output of
 * `scripts/license/generate-keypair.mjs`. The SDK refuses to validate
 * licenses against the placeholder kid `"placeholder-do-not-ship"`
 * unless DVAI_LICENSE_ALLOW_PLACEHOLDER=1 is set (test-only escape hatch).
 *
 * Adding a new key for rotation:
 *
 *   export const DVAI_PUBLIC_KEYS: Record<string, DvaiPublicKeyJwk> = {
 *     "2026-05": { kty: "EC", crv: "P-256", x: "...", y: "...", alg: "ES256", use: "sig", kid: "2026-05" },
 *     "2027-01": { kty: "EC", crv: "P-256", x: "...", y: "...", alg: "ES256", use: "sig", kid: "2027-01" },
 *   };
 */
export const DVAI_PUBLIC_KEYS: Record<string, DvaiPublicKeyJwk> = {
  // Production key, kid `2026-05`. Generated 2026-05-15 by
  // scripts/license/generate-keypair.mjs. The matching private key
  // lives in the operator's secrets manager.
  "2026-05": {
    kty: "EC",
    crv: "P-256",
    x: "2Y8TuhnlE4tiVDtliozYTgc1TAqi4_TBTI6FHe1p_Vw",
    y: "pyxMJHj10HPe2hnpJvMpnZ4AzpYZRfqGEMhpBr1-Oto",
    alg: "ES256",
    use: "sig",
    kid: "2026-05",
  },
  // PLACEHOLDER — used by the SDK's own unit tests and by the sample
  // license printed by `generate-keypair.mjs`. The validator REFUSES to
  // accept tokens signed under this kid unless allowPlaceholderKey is
  // explicitly set (DVAI_LICENSE_ALLOW_PLACEHOLDER=1 env var, or the
  // allowPlaceholderKey constructor option). Safe to keep in production
  // builds; remove only if you want test fixtures to stop working.
  "placeholder-do-not-ship": {
    kty: "EC",
    crv: "P-256",
    x: "MKBCTNIcKUSDii11ySs3526iDZ8AiTo7Tu6KPAqv7D4",
    y: "4Etl6SRW2YiLUrN5vfvVHuhp7x8PxltmWWlbbM4IFyM",
    alg: "ES256",
    use: "sig",
    kid: "placeholder-do-not-ship",
  },
};

/**
 * `kid` reserved for the placeholder key above. The validator refuses to
 * accept tokens signed with this kid unless the caller explicitly opts
 * in (DVAI_LICENSE_ALLOW_PLACEHOLDER=1 or `allowPlaceholderKey: true`
 * passed to the validator constructor). Used by tests and by the
 * sample license printed by `generate-keypair.mjs`.
 */
export const PLACEHOLDER_KID = "placeholder-do-not-ship";
