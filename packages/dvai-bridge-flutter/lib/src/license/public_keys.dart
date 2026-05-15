// Public-key registry for DVAI-Bridge license JWT verification.
//
// Each entry is keyed by `kid` (key id, written by the license generator
// into the JWT header). The SDK looks up the matching entry by kid when
// verifying a license token. Multiple entries can coexist so that key
// rotation is non-disruptive: ship the new key in a release alongside
// the old, leave the old in place for ~12 months while previously-
// issued licenses naturally expire or get re-issued, then prune.
//
// THE PRIVATE KEY DOES NOT LIVE HERE. It belongs in your secrets
// manager (1Password / AWS Secrets Manager / Vault), accessible only
// to the license-generator service that produces signed JWTs. The
// mathematics of ECDSA P-256 guarantee that a holder of the public
// key alone cannot forge a signature.
//
// To populate this registry:
//   1. Run `node scripts/license/generate-keypair.mjs` (in the
//      monorepo root — see that script's comment for full instructions)
//   2. Paste the printed PUBLIC key JWK as an entry below
//   3. Move the printed PRIVATE key into your secrets store
//   4. Wire your license-generator backend to use the private key

import 'package:meta/meta.dart';

/// ES256 (P-256 ECDSA) public key in JWK form. Mirrors the JS-side
/// `DvaiPublicKeyJwk` interface: every other DVAI-Bridge SDK consumes
/// the same JWK shape so the same `.jwt` license file works across
/// platforms.
@immutable
class DvaiPublicKey {
  /// Construct a key from its JWK fields. `kty` is fixed at `"EC"` and
  /// `crv` at `"P-256"` since the registry only carries ES256 keys.
  const DvaiPublicKey({
    required this.x,
    required this.y,
    this.kid,
    this.alg = 'ES256',
    this.use = 'sig',
  });

  /// Key type. Always `"EC"`.
  String get kty => 'EC';

  /// Curve. Always `"P-256"`.
  String get crv => 'P-256';

  /// Base64url-encoded X coordinate.
  final String x;

  /// Base64url-encoded Y coordinate.
  final String y;

  /// Optional algorithm hint. Defaults to `"ES256"`.
  final String alg;

  /// Optional usage hint. Defaults to `"sig"`.
  final String use;

  /// Optional key id. Mirrors the `kid` header claim the generator
  /// writes into the JWT header.
  final String? kid;

  /// Encode to the JWK Map shape that `JWTKey.fromJWK` consumes from
  /// `dart_jsonwebtoken`.
  Map<String, dynamic> toJwk() {
    return <String, dynamic>{
      'kty': kty,
      'crv': crv,
      'x': x,
      'y': y,
      'alg': alg,
      'use': use,
      if (kid != null) 'kid': kid,
    };
  }
}

/// Registry mapping `kid` → public key JWK.
///
/// WARNING — the entry below is a **placeholder** — it is a published,
/// well-known test keypair and DOES NOT verify any real production
/// license. Before shipping licenses to customers, replace it with the
/// output of `scripts/license/generate-keypair.mjs` in the monorepo
/// root. The SDK refuses to validate licenses against the placeholder
/// kid `"placeholder-do-not-ship"` unless `allowPlaceholderKey: true`
/// is passed to the [LicenseValidator] constructor (test-only escape
/// hatch).
///
/// Adding a new key for rotation:
///
/// ```dart
/// const Map<String, DvaiPublicKey> publicKeys = <String, DvaiPublicKey>{
///   '2026-05': DvaiPublicKey(x: '...', y: '...', kid: '2026-05'),
///   '2027-01': DvaiPublicKey(x: '...', y: '...', kid: '2027-01'),
/// };
/// ```
const Map<String, DvaiPublicKey> publicKeys = <String, DvaiPublicKey>{
  // Production key, kid `2026-05`. Generated 2026-05-15 by
  // scripts/license/generate-keypair.mjs. The matching private key
  // lives in the operator's secrets manager.
  '2026-05': DvaiPublicKey(
    x: '2Y8TuhnlE4tiVDtliozYTgc1TAqi4_TBTI6FHe1p_Vw',
    y: 'pyxMJHj10HPe2hnpJvMpnZ4AzpYZRfqGEMhpBr1-Oto',
    kid: '2026-05',
  ),
  // PLACEHOLDER — used by the SDK's own unit tests and by the sample
  // license printed by `generate-keypair.mjs`. The validator REFUSES
  // to accept tokens signed under this kid unless
  // `allowPlaceholderKey: true` is passed to the [LicenseValidator]
  // constructor (test-only escape hatch). Safe to keep in production
  // builds; remove only if you want test fixtures to stop working.
  'placeholder-do-not-ship': DvaiPublicKey(
    x: 'MKBCTNIcKUSDii11ySs3526iDZ8AiTo7Tu6KPAqv7D4',
    y: '4Etl6SRW2YiLUrN5vfvVHuhp7x8PxltmWWlbbM4IFyM',
    kid: 'placeholder-do-not-ship',
  ),
};

/// `kid` reserved for the placeholder key above. The validator refuses
/// to accept tokens signed with this kid unless the caller explicitly
/// opts in (`allowPlaceholderKey: true` passed to the
/// [LicenseValidator] constructor). Used by tests and by the sample
/// license printed by `generate-keypair.mjs`.
const String placeholderKid = 'placeholder-do-not-ship';
