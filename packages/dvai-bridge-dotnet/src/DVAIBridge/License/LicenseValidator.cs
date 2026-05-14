// <copyright file="LicenseValidator.cs" company="Deep Voice AI">
//   Copyright (c) 2026 Deep Voice AI. All rights reserved.
// </copyright>

using System;
using System.Collections.Generic;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;

namespace DVAIBridge.License;

/// <summary>
/// Options controlling <see cref="LicenseValidator"/> behaviour. Extends
/// <see cref="LicenseDiscoveryOptions"/> with public-key override + the
/// placeholder-key opt-in escape hatch used by tests.
/// </summary>
public sealed record LicenseValidatorOptions
{
    /// <summary>
    /// Pre-loaded JWT string (skips discovery). Mirrors
    /// <see cref="LicenseDiscoveryOptions.Token"/>.
    /// </summary>
    public string? Token { get; init; }

    /// <summary>
    /// Explicit path to load the token from. Mirrors
    /// <see cref="LicenseDiscoveryOptions.Path"/>.
    /// </summary>
    public string? Path { get; init; }

    /// <summary>
    /// Override the public-key registry. Defaults to
    /// <see cref="PublicKeys.Default"/>. Tests inject their own keypair
    /// here so they can sign + verify against a deterministic key
    /// without polluting the production registry.
    /// </summary>
    public IReadOnlyDictionary<string, DvaiPublicKey>? PublicKeys { get; init; }

    /// <summary>
    /// If <c>true</c>, accept tokens signed under
    /// <see cref="License.PublicKeys.PlaceholderKid"/> (the built-in
    /// placeholder public key). Off by default — a real production
    /// build must replace the placeholder with a generated key. Tests
    /// set this to true.
    /// </summary>
    public bool AllowPlaceholderKey { get; init; }
}

/// <summary>
/// Validate a DVAI-Bridge license once at SDK startup. The returned
/// <see cref="LicenseStatus"/> is the discriminated value the rest of
/// the SDK dispatches on.
///
/// <para>Two entry points:</para>
/// <list type="bullet">
/// <item><see cref="ValidateAsync(CancellationToken)"/> — never throws on
/// validation failure; returns a <c>FreeProd</c> / <c>FreeExpired</c>
/// status. Used by host-app dashboards.</item>
/// <item><see cref="ValidateAndAssertAsync(CancellationToken)"/> — throws
/// <see cref="LicenseRequiredException"/> for <c>FreeProd</c> /
/// <c>FreeExpired</c>. This is the BSL 1.1 enforcement point.</item>
/// </list>
///
/// <para>
/// Network calls: zero. The whole flow is offline by design — no
/// "phone home" step, no license-server polling, no DRM beacon.
/// </para>
/// </summary>
public sealed class LicenseValidator
{
    private readonly LicenseValidatorOptions _opts;

    /// <summary>
    /// Initializes a new instance of the <see cref="LicenseValidator"/>
    /// class with the given options.
    /// </summary>
    /// <param name="opts">Optional validator options.</param>
    public LicenseValidator(LicenseValidatorOptions? opts = null)
    {
        _opts = opts ?? new LicenseValidatorOptions();
    }

    /// <summary>
    /// Validate WITHOUT throwing. Returns a <see cref="LicenseStatus"/>
    /// describing what the validator determined; never throws on
    /// missing / invalid / expired licenses. Useful for host-app
    /// dashboards that want to display the licensee / expiry /
    /// fallback reason without halting SDK startup, and for tests.
    /// </summary>
    /// <param name="ct">Cancellation token for file I/O.</param>
    /// <returns>The validation outcome.</returns>
    public async Task<LicenseStatus> ValidateAsync(CancellationToken ct = default)
    {
        // 1. Dev-mode bypass — license required only in production.
        var dev = Audience.DetectDevMode();
        if (dev.IsDev)
        {
            return new LicenseStatus.FreeDev(dev.Reason);
        }

        // 2. Discover the token. null means no license source is
        //    configured AND auto-discovery failed.
        var discovered = await Discovery.DiscoverLicenseTokenAsync(
            new LicenseDiscoveryOptions { Token = _opts.Token, Path = _opts.Path },
            ct).ConfigureAwait(false);
        if (discovered is null)
        {
            return new LicenseStatus.FreeProd(
                "no license token found; checked options.Token, options.Path, " +
                "DVAI_LICENSE_PATH env, DVAI_LICENSE_TOKEN env, and platform-default paths");
        }

        // 3. Verify signature + claims.
        var platform = Audience.DetectPlatform();
        var runtimeAudience = Audience.DetectAudience();
        return VerifyToken(discovered.Token, platform, runtimeAudience);
    }

    /// <summary>
    /// Strict validation entry point used by the SDK at startup.
    /// Returns <see cref="LicenseStatus"/> on success
    /// (<c>Commercial</c>, <c>Trial</c>, <c>FreeDev</c>) and THROWS
    /// <see cref="LicenseRequiredException"/> on <c>FreeProd</c> /
    /// <c>FreeExpired</c>.
    ///
    /// <para>
    /// This is the BSL 1.1 enforcement point: in production / release
    /// builds (any non-dev-mode environment), the SDK refuses to
    /// operate without a valid commercial or trial license. Developers
    /// running on debug builds / debugger-attached / explicit
    /// <c>DVAI_FORCE_DEV</c> are unaffected — those return a
    /// <c>FreeDev</c> status and the SDK proceeds normally.
    /// </para>
    /// </summary>
    /// <param name="ct">Cancellation token for file I/O.</param>
    /// <returns>The validation outcome (never <c>FreeProd</c> / <c>FreeExpired</c>).</returns>
    /// <exception cref="LicenseRequiredException">
    /// Thrown when validation produces <c>FreeProd</c> or
    /// <c>FreeExpired</c> — i.e. in production without a valid license.
    /// </exception>
    public async Task<LicenseStatus> ValidateAndAssertAsync(CancellationToken ct = default)
    {
        var status = await ValidateAsync(ct).ConfigureAwait(false);
        if (status is LicenseStatus.FreeProd or LicenseStatus.FreeExpired)
        {
            throw new LicenseRequiredException(BuildRequiredErrorMessage(status), status);
        }

        return status;
    }

    private LicenseStatus VerifyToken(string token, DvaiPlatform platform, string? runtimeAudience)
    {
        var registry = _opts.PublicKeys ?? PublicKeys.Default;

        // 1. Read and validate the JWT header out-of-band so we can give
        //    specific failure reasons rather than a single opaque "verify
        //    failed" code from the JWT library.
        var parts = token.Split('.');
        if (parts.Length != 3 || string.IsNullOrEmpty(parts[0]))
        {
            return new LicenseStatus.FreeProd(
                "license token is not a well-formed JWT (need 3 segments)");
        }

        JwtHeader header;
        try
        {
            var headerJson = Base64UrlDecodeUtf8(parts[0]);
            header = JsonSerializer.Deserialize<JwtHeader>(headerJson)
                ?? throw new InvalidOperationException("header deserialized to null");
        }
        catch (Exception ex)
        {
            return new LicenseStatus.FreeProd(
                $"license token header is not parseable JSON: {ex.Message}");
        }

        if (header.Alg != "ES256")
        {
            // Refuse `alg: none` and any non-ES256 algorithm. Critical
            // defense against the classic JWT algorithm-confusion attack.
            return new LicenseStatus.FreeProd(
                $"license token uses unsupported alg \"{header.Alg ?? "(missing)"}\", expected ES256");
        }

        if (string.IsNullOrEmpty(header.Kid))
        {
            return new LicenseStatus.FreeProd(
                "license token header missing kid; cannot select verification key");
        }

        if (!registry.TryGetValue(header.Kid, out var jwk))
        {
            return new LicenseStatus.FreeProd(
                $"license token kid \"{header.Kid}\" is not in the SDK's public-key " +
                "registry; either the key was rotated and you're on an old SDK, " +
                "or the token was signed with a key we don't recognise");
        }

        if (header.Kid == PublicKeys.PlaceholderKid && !_opts.AllowPlaceholderKey)
        {
            return new LicenseStatus.FreeProd(
                $"license token signed with the placeholder key (kid \"{PublicKeys.PlaceholderKid}\"); " +
                "replace the placeholder in PublicKeys.cs with a real key generated " +
                "via scripts/license/generate-keypair.mjs before issuing real licenses");
        }

        // 2. Verify signature with Microsoft.IdentityModel.JsonWebTokens.
        //    Audience + expiry are checked manually below so the
        //    failure reasons are specific rather than generic.
        var handler = new JsonWebTokenHandler();
        SecurityKey key;
        try
        {
            key = JwkToEcdsaKey(jwk);
        }
        catch (Exception ex)
        {
            return new LicenseStatus.FreeProd(
                $"license token public key (kid \"{header.Kid}\") is malformed: {ex.Message}");
        }

        var validationParams = new TokenValidationParameters
        {
            ValidateIssuer = true,
            ValidIssuer = "DVAI-Bridge",
            ValidateAudience = false, // checked manually below
            ValidateLifetime = true,
            ValidateIssuerSigningKey = true,
            IssuerSigningKey = key,
            ValidAlgorithms = new[] { SecurityAlgorithms.EcdsaSha256 },
            ClockSkew = TimeSpan.Zero,
        };

        TokenValidationResult result;
        try
        {
            result = handler.ValidateTokenAsync(token, validationParams).GetAwaiter().GetResult();
        }
        catch (Exception ex)
        {
            return new LicenseStatus.FreeProd(
                $"license token verification failed: {ex.Message}");
        }

        if (!result.IsValid)
        {
            // Walk the exception chain so wrapped failures (some IdentityModel
            // paths wrap SecurityTokenExpiredException inside a generic
            // SecurityTokenException) classify correctly.
            var ex = result.Exception;
            while (ex is not null)
            {
                if (ex is SecurityTokenExpiredException)
                {
                    var jwtExpired = handler.ReadJsonWebToken(token);
                    var expiredLicensee = TryReadStringClaim(jwtExpired, "licensee") ?? "(unknown)";
                    var expiredAt = TryReadLongClaim(jwtExpired, "exp") ?? 0;
                    return new LicenseStatus.FreeExpired(expiredLicensee, expiredAt);
                }

                if (ex is SecurityTokenInvalidSignatureException
                    || ex is SecurityTokenSignatureKeyNotFoundException)
                {
                    return new LicenseStatus.FreeProd(
                        $"license token signature did not verify against kid \"{header.Kid}\"; " +
                        "the token may have been tampered with or was signed by a different key");
                }

                if (ex is SecurityTokenInvalidIssuerException issuerEx)
                {
                    return new LicenseStatus.FreeProd(
                        $"license token claim \"iss\" failed: {issuerEx.Message}");
                }

                ex = ex.InnerException;
            }

            // Fallback for the exception type at the outer level if the chain
            // walk didn't classify it. Some IdentityModel versions surface
            // expired tokens via the message rather than a typed exception.
            var msg = result.Exception?.Message ?? "unknown error";
            if (msg.Contains("IDX10223", StringComparison.Ordinal)
                || msg.Contains("expired", StringComparison.OrdinalIgnoreCase))
            {
                var jwtExpired = handler.ReadJsonWebToken(token);
                var expiredLicensee = TryReadStringClaim(jwtExpired, "licensee") ?? "(unknown)";
                var expiredAt = TryReadLongClaim(jwtExpired, "exp") ?? 0;
                return new LicenseStatus.FreeExpired(expiredLicensee, expiredAt);
            }

            return new LicenseStatus.FreeProd($"license token verification failed: {msg}");
        }

        // 3. Coerce + validate the payload shape ourselves (the JWT
        //    library only checks standard claims). Each branch below
        //    provides a specific FreeProd reason so the developer can
        //    fix exactly what's wrong.
        var jwt = (JsonWebToken)result.SecurityToken;

        var tier = TryReadStringClaim(jwt, "tier");
        if (tier != "commercial" && tier != "trial")
        {
            return new LicenseStatus.FreeProd(
                "license token payload missing required DVAI fields (tier/platforms/aud/licensee)");
        }

        var platforms = TryReadStringArrayClaim(jwt, "platforms");
        var audClaims = TryReadStringArrayClaim(jwt, "aud");
        var licensee = TryReadStringClaim(jwt, "licensee");
        var expSeconds = TryReadLongClaim(jwt, "exp");

        if (platforms is null || audClaims is null || licensee is null || expSeconds is null)
        {
            return new LicenseStatus.FreeProd(
                "license token payload missing required DVAI fields (tier/platforms/aud/licensee)");
        }

        var platformString = PlatformToString(platform);
        if (!platforms.Contains(platformString))
        {
            return new LicenseStatus.FreeProd(
                $"license token does not authorise platform \"{platformString}\"; " +
                $"the token covers [{string.Join(", ", platforms)}]");
        }

        var matched = Audience.MatchAudience(runtimeAudience, audClaims);
        if (matched is null)
        {
            var hint = runtimeAudience is null
                ? " — set DVAI_AUDIENCE in your environment, or use a \"*\" aud entry for any-domain licenses"
                : string.Empty;
            return new LicenseStatus.FreeProd(
                $"license token's audience entries [{string.Join(", ", audClaims)}] " +
                $"do not match the current runtime audience \"{runtimeAudience ?? "(none)"}\"" +
                hint);
        }

        return tier == "commercial"
            ? new LicenseStatus.Commercial(licensee, expSeconds.Value, platform, matched)
            : new LicenseStatus.Trial(licensee, expSeconds.Value, platform, matched);
    }

    /* ----------------------------------------------------------------- */
    /* Helpers                                                            */
    /* ----------------------------------------------------------------- */

    private static string PlatformToString(DvaiPlatform p) => p switch
    {
        DvaiPlatform.Web => "web",
        DvaiPlatform.Node => "node",
        DvaiPlatform.IOS => "ios",
        DvaiPlatform.Android => "android",
        DvaiPlatform.Dotnet => "dotnet",
        DvaiPlatform.Flutter => "flutter",
        DvaiPlatform.ReactNative => "react-native",
        DvaiPlatform.Capacitor => "capacitor",
        _ => throw new ArgumentOutOfRangeException(nameof(p), p, null),
    };

    private static ECDsaSecurityKey JwkToEcdsaKey(DvaiPublicKey jwk)
    {
        if (jwk.Kty != "EC")
        {
            throw new InvalidOperationException($"unsupported JWK kty \"{jwk.Kty}\", expected EC");
        }

        if (jwk.Crv != "P-256")
        {
            throw new InvalidOperationException($"unsupported JWK crv \"{jwk.Crv}\", expected P-256");
        }

        var x = Base64UrlDecodeBytes(jwk.X);
        var y = Base64UrlDecodeBytes(jwk.Y);
        var ecdsa = ECDsa.Create(new ECParameters
        {
            Curve = ECCurve.NamedCurves.nistP256,
            Q = new ECPoint { X = x, Y = y },
        });
        return new ECDsaSecurityKey(ecdsa);
    }

    private static string Base64UrlDecodeUtf8(string s)
    {
        return Encoding.UTF8.GetString(Base64UrlDecodeBytes(s));
    }

    private static byte[] Base64UrlDecodeBytes(string s)
    {
        var pad = s.Length % 4 == 0 ? string.Empty : new string('=', 4 - (s.Length % 4));
        var b64 = s.Replace('-', '+').Replace('_', '/') + pad;
        return Convert.FromBase64String(b64);
    }

    private static string? TryReadStringClaim(JsonWebToken jwt, string name)
    {
        return jwt.TryGetPayloadValue<string>(name, out var v) ? v : null;
    }

    private static long? TryReadLongClaim(JsonWebToken jwt, string name)
    {
        if (jwt.TryGetPayloadValue<long>(name, out var v))
        {
            return v;
        }

        if (jwt.TryGetPayloadValue<double>(name, out var d))
        {
            return (long)d;
        }

        return null;
    }

    private static IReadOnlyList<string>? TryReadStringArrayClaim(JsonWebToken jwt, string name)
    {
        // JsonWebToken stores claim arrays as List<string> after deserialization.
        if (jwt.TryGetPayloadValue<List<string>>(name, out var list) && list is not null)
        {
            return list;
        }

        if (jwt.TryGetPayloadValue<string[]>(name, out var arr) && arr is not null)
        {
            return arr;
        }

        // A single-element aud is sometimes serialized as a string instead of a list.
        if (jwt.TryGetPayloadValue<string>(name, out var single) && single is not null)
        {
            return new[] { single };
        }

        return null;
    }

    private sealed record JwtHeader(
        [property: System.Text.Json.Serialization.JsonPropertyName("alg")] string? Alg,
        [property: System.Text.Json.Serialization.JsonPropertyName("typ")] string? Typ,
        [property: System.Text.Json.Serialization.JsonPropertyName("kid")] string? Kid);

    /// <summary>
    /// Build the developer-facing error message for
    /// <see cref="LicenseRequiredException"/>. Intentionally verbose: it
    /// tells the developer exactly what failed, how to resolve it,
    /// where to put the license file, and how to bypass for local
    /// development.
    /// </summary>
    /// <param name="status">The validator status to render.</param>
    /// <returns>The verbose error message.</returns>
    private static string BuildRequiredErrorMessage(LicenseStatus status)
    {
        const string header =
            "\nDVAI-Bridge Commercial License Required\n" +
            "=======================================\n";

        var reason = status switch
        {
            LicenseStatus.FreeExpired expired =>
                $"License for \"{expired.Licensee}\" expired at " +
                $"{DateTimeOffset.FromUnixTimeSeconds(expired.ExpiredAt).ToString("O", System.Globalization.CultureInfo.InvariantCulture)}.",
            LicenseStatus.FreeProd prod => prod.Reason,
            _ => "(unknown status)",
        };

        const string remediation =
            "\nThis SDK is licensed under BSL 1.1 and requires a valid commercial\n" +
            "or trial license to run in production / release builds.\n" +
            "\n" +
            "To resolve:\n" +
            "  1. Obtain a license at https://deepvoiceai.com/dvai-bridge/license\n" +
            "  2. Place the file at one of these locations (any will work):\n" +
            "       - alongside your executable / dvai-license.jwt (auto-discovered)\n" +
            "       - %LOCALAPPDATA%/dvai-bridge/dvai-license.jwt (per-user)\n" +
            "       - the path you pass as StartOptions.LicenseKeyPath\n" +
            "       - the path in $DVAI_LICENSE_PATH\n" +
            "       - inline JWT in StartOptions.LicenseToken or $DVAI_LICENSE_TOKEN\n" +
            "  3. Re-run.\n" +
            "\n" +
            "Developing locally? The SDK auto-detects dev mode on:\n" +
            "  - Debug builds (DEBUG compile flag)\n" +
            "  - Debugger attached (Debugger.IsAttached)\n" +
            "  - DVAI_FORCE_DEV=1 environment variable (explicit override)\n" +
            "Any of these silences this error and lets the SDK run without a\n" +
            "license.\n";

        return header + "\n" + reason + "\n" + remediation;
    }
}
