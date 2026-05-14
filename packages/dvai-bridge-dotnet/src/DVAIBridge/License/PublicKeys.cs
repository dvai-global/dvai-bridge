// <copyright file="PublicKeys.cs" company="Deep Voice AI">
//   Copyright (c) 2026 Deep Voice AI. All rights reserved.
// </copyright>

using System.Collections.Generic;

namespace DVAIBridge.License;

/// <summary>
/// Public-key registry for DVAI-Bridge license JWT verification.
///
/// <para>
/// Each entry is keyed by <c>kid</c> (key id, written by the license
/// generator into the JWT header). The SDK looks up the matching entry by
/// kid when verifying a license token. Multiple entries can coexist so
/// that key rotation is non-disruptive: ship the new key in a release
/// alongside the old, leave the old in place for ~12 months while
/// previously-issued licenses naturally expire or get re-issued, then
/// prune.
/// </para>
///
/// <para>
/// THE PRIVATE KEY DOES NOT LIVE HERE. It belongs in your secrets
/// manager (1Password / AWS Secrets Manager / Vault), accessible only
/// to the license-generator service that produces signed JWTs. The
/// mathematics of ECDSA P-256 guarantee that a holder of the public
/// key alone cannot forge a signature.
/// </para>
/// </summary>
/// <param name="Kty">JWK key type. Always <c>"EC"</c> for ES256.</param>
/// <param name="Crv">JWK curve. Always <c>"P-256"</c> for ES256.</param>
/// <param name="X">Base64url-encoded X coordinate of the EC public point.</param>
/// <param name="Y">Base64url-encoded Y coordinate of the EC public point.</param>
/// <param name="Alg">Optional JWK alg parameter. Defaults to <c>"ES256"</c>.</param>
/// <param name="Use">Optional JWK use parameter. Defaults to <c>"sig"</c>.</param>
/// <param name="Kid">
/// Optional kid hint embedded in the JWK. Typically equal to the
/// registry key for the same entry.
/// </param>
public sealed record DvaiPublicKey(
    string Kty,
    string Crv,
    string X,
    string Y,
    string? Alg = "ES256",
    string? Use = "sig",
    string? Kid = null);

/// <summary>
/// Static registry mapping <c>kid</c> → <see cref="DvaiPublicKey"/>.
/// Mirrors <c>DVAI_PUBLIC_KEYS</c> in the JS-side <c>publicKeys.ts</c>.
/// </summary>
public static class PublicKeys
{
    /// <summary>
    /// <c>kid</c> reserved for the placeholder key below. The validator
    /// refuses to accept tokens signed with this kid unless the caller
    /// explicitly opts in (<c>DVAI_LICENSE_ALLOW_PLACEHOLDER=1</c> or
    /// <c>AllowPlaceholderKey = true</c> passed to the validator
    /// constructor). Used by tests and by the sample license printed by
    /// <c>scripts/license/generate-keypair.mjs</c>.
    /// </summary>
    public const string PlaceholderKid = "placeholder-do-not-ship";

    /// <summary>
    /// Default public-key registry. The placeholder entry below is the
    /// same well-known test keypair the JS SDK ships with — replace
    /// before issuing real licenses.
    /// </summary>
    public static readonly IReadOnlyDictionary<string, DvaiPublicKey> Default =
        new Dictionary<string, DvaiPublicKey>
        {
            // PLACEHOLDER — replace with the output of
            // scripts/license/generate-keypair.mjs before issuing any real
            // licenses. See DvaiPublicKey above for the full rotation
            // procedure.
            [PlaceholderKid] = new DvaiPublicKey(
                Kty: "EC",
                Crv: "P-256",
                X: "MKBCTNIcKUSDii11ySs3526iDZ8AiTo7Tu6KPAqv7D4",
                Y: "4Etl6SRW2YiLUrN5vfvVHuhp7x8PxltmWWlbbM4IFyM",
                Alg: "ES256",
                Use: "sig",
                Kid: PlaceholderKid),
        };
}
