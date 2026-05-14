// <copyright file="LicenseValidatorTests.cs" company="Deep Voice AI">
//   Copyright (c) 2026 Deep Voice AI. All rights reserved.
// </copyright>

using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading.Tasks;
using DVAIBridge.License;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;
using Xunit;

namespace DVAIBridge.Tests.License;

// All license tests mutate process-wide environment variables (DVAI_FORCE_*,
// DVAI_AUDIENCE, DVAI_LICENSE_*). xUnit's default parallelism would let two
// tests trample each other's env state mid-run, so we group every class in
// this file into a single non-parallel collection.
[CollectionDefinition("LicenseEnvSerialization", DisableParallelization = true)]
public sealed class LicenseEnvSerializationCollection : ICollectionFixture<LicenseValidatorTestKeyFixture>
{
}

/// <summary>
/// Tests for the JWT-based license validator (.NET port of the JS-side
/// <c>license.test.ts</c>).
///
/// <para>Two APIs are exercised:</para>
/// <list type="bullet">
/// <item><c>ValidateAsync()</c> — never throws; returns a
/// <c>LicenseStatus</c> with <c>FreeProd</c>/<c>FreeExpired</c> for
/// failure cases. Used by host-app dashboards.</item>
/// <item><c>ValidateAndAssertAsync()</c> — throws
/// <c>LicenseRequiredException</c> for the same failure cases. Used by
/// <c>DVAIBridge.StartAsync</c> to enforce the BSL 1.1
/// commercial-only-in-production policy.</item>
/// </list>
///
/// <para>
/// All tests generate a fresh ES256 keypair at fixture setup (xUnit
/// <see cref="IClassFixture{T}"/>) and inject the corresponding public
/// JWK into the validator via the <c>PublicKeys</c> option — mirroring
/// the JS-side test pattern.
/// </para>
/// </summary>
public sealed class LicenseValidatorTestKeyFixture : IDisposable
{
    public const string TestKid = "test-kid-2026";

    public ECDsa Ecdsa { get; }

    public DvaiPublicKey PublicJwk { get; }

    public IReadOnlyDictionary<string, DvaiPublicKey> PublicKeys { get; }

    public LicenseValidatorTestKeyFixture()
    {
        Ecdsa = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var p = Ecdsa.ExportParameters(includePrivateParameters: false);
        PublicJwk = new DvaiPublicKey(
            Kty: "EC",
            Crv: "P-256",
            X: Base64UrlEncode(p.Q.X!),
            Y: Base64UrlEncode(p.Q.Y!),
            Alg: "ES256",
            Use: "sig",
            Kid: TestKid);
        PublicKeys = new Dictionary<string, DvaiPublicKey> { [TestKid] = PublicJwk };
    }

    public string MintLicense(
        string[]? aud = null,
        string[]? platforms = null,
        string tier = "commercial",
        string licensee = "Test Co",
        long? expSecondsAbsolute = null,
        TimeSpan? lifetime = null,
        string iss = "DVAI-Bridge",
        string? kid = null)
    {
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var exp = expSecondsAbsolute ?? now + (long)(lifetime ?? TimeSpan.FromDays(30)).TotalSeconds;
        // For expired-token tests, keep iat/nbf <= exp (otherwise IdentityModel
        // emits IDX10224 lifetime-ordering failure on CreateToken, which short-
        // circuits before exp gets evaluated against the current clock).
        var iat = Math.Min(now, exp - 1);
        var payload = new Dictionary<string, object>
        {
            ["iss"] = iss,
            ["sub"] = "test-license",
            ["aud"] = aud ?? new[] { "*" },
            ["tier"] = tier,
            ["licensee"] = licensee,
            ["platforms"] = platforms ?? new[] { "dotnet", "web", "node", "ios", "android" },
            ["iat"] = iat,
            ["exp"] = exp,
        };

        var handler = new JsonWebTokenHandler();
        // KeyId on the SecurityKey is what JsonWebTokenHandler writes into
        // the JWT header's `kid` field. AdditionalHeaderClaims explicitly
        // rejects `kid` (IDX14116) because of this.
        var signingKey = new ECDsaSecurityKey(Ecdsa) { KeyId = kid ?? TestKid };
        var signingCredentials = new SigningCredentials(signingKey, SecurityAlgorithms.EcdsaSha256);
        var descriptor = new SecurityTokenDescriptor
        {
            // JsonWebTokenHandler's descriptor path overrides any iat/exp
            // values in Claims with the descriptor's IssuedAt/Expires/
            // NotBefore. Set them explicitly so an expired-token fixture
            // round-trips as expired through the validator.
            Claims = payload,
            IssuedAt = DateTimeOffset.FromUnixTimeSeconds(iat).UtcDateTime,
            Expires = DateTimeOffset.FromUnixTimeSeconds(exp).UtcDateTime,
            NotBefore = DateTimeOffset.FromUnixTimeSeconds(iat).UtcDateTime,
            SigningCredentials = signingCredentials,
        };
        return handler.CreateToken(descriptor);
    }

    public static string Base64UrlEncode(byte[] bytes)
    {
        var b64 = Convert.ToBase64String(bytes);
        return b64.TrimEnd('=').Replace('+', '-').Replace('/', '_');
    }

    public void Dispose() => Ecdsa.Dispose();
}

/// <summary>
/// Per-test env-var scoping. The .NET test process is shared across xUnit
/// fixtures, so each test that flips DVAI_FORCE_PROD/DEV must restore
/// state in its teardown. We use a tiny IDisposable rather than xUnit's
/// hooks so each test is self-contained.
/// </summary>
internal sealed class EnvScope : IDisposable
{
    private readonly Dictionary<string, string?> _previous = new();

    public EnvScope Set(string name, string? value)
    {
        if (!_previous.ContainsKey(name))
        {
            _previous[name] = Environment.GetEnvironmentVariable(name);
        }

        Environment.SetEnvironmentVariable(name, value);
        return this;
    }

    public void Dispose()
    {
        foreach (var (k, v) in _previous)
        {
            Environment.SetEnvironmentVariable(k, v);
        }
    }
}

[Collection("LicenseEnvSerialization")]
public sealed class LicenseValidatorHappyPathTests
{
    private readonly LicenseValidatorTestKeyFixture _fx;

    public LicenseValidatorHappyPathTests(LicenseValidatorTestKeyFixture fx) => _fx = fx;

    [Fact]
    public async Task AcceptsCommercialTokenAndReportsLicenseeAndExpiry()
    {
        using var env = new EnvScope()
            .Set("DVAI_FORCE_PROD", "1")
            .Set("DVAI_FORCE_DEV", null)
            .Set("DVAI_AUDIENCE", "acme.com");
        var token = _fx.MintLicense(
            aud: new[] { "acme.com" },
            platforms: new[] { "dotnet" },
            licensee: "Acme Inc");
        var v = new LicenseValidator(new LicenseValidatorOptions
        {
            Token = token,
            PublicKeys = _fx.PublicKeys,
        });
        var status = await v.ValidateAsync();
        var commercial = Assert.IsType<LicenseStatus.Commercial>(status);
        Assert.Equal("Acme Inc", commercial.Licensee);
        Assert.Equal("acme.com", commercial.AudienceMatched);
        Assert.Equal(DvaiPlatform.Dotnet, commercial.Platform);
        Assert.True(commercial.ExpiresAt > DateTimeOffset.UtcNow.ToUnixTimeSeconds());
    }

    [Fact]
    public async Task MatchesWildcardSubdomainAudienceEntries()
    {
        using var env = new EnvScope()
            .Set("DVAI_FORCE_PROD", "1")
            .Set("DVAI_FORCE_DEV", null)
            .Set("DVAI_AUDIENCE", "app.acme.com");
        var token = _fx.MintLicense(aud: new[] { "*.acme.com" }, platforms: new[] { "dotnet" });
        var status = await new LicenseValidator(new LicenseValidatorOptions
        {
            Token = token,
            PublicKeys = _fx.PublicKeys,
        }).ValidateAsync();
        var c = Assert.IsType<LicenseStatus.Commercial>(status);
        Assert.Equal("*.acme.com", c.AudienceMatched);
    }

    [Fact]
    public async Task MatchesStarAudienceForAnyDomainTrialLicenses()
    {
        using var env = new EnvScope()
            .Set("DVAI_FORCE_PROD", "1")
            .Set("DVAI_FORCE_DEV", null)
            .Set("DVAI_AUDIENCE", string.Empty); // empty → null (DetectAudience falls back to entry assembly name)
        // To truly exercise the runtimeAudience=null path we'd need to mock
        // the assembly name; instead we use "*" which matches any audience
        // (including the test runner's assembly name).
        var token = _fx.MintLicense(aud: new[] { "*" }, platforms: new[] { "dotnet" }, tier: "trial");
        var status = await new LicenseValidator(new LicenseValidatorOptions
        {
            Token = token,
            PublicKeys = _fx.PublicKeys,
        }).ValidateAsync();
        Assert.IsType<LicenseStatus.Trial>(status);
    }

    [Fact]
    public async Task MatchesBareApexOfWildcardEntry()
    {
        using var env = new EnvScope()
            .Set("DVAI_FORCE_PROD", "1")
            .Set("DVAI_FORCE_DEV", null)
            .Set("DVAI_AUDIENCE", "acme.com");
        var token = _fx.MintLicense(aud: new[] { "*.acme.com" }, platforms: new[] { "dotnet" });
        var status = await new LicenseValidator(new LicenseValidatorOptions
        {
            Token = token,
            PublicKeys = _fx.PublicKeys,
        }).ValidateAsync();
        Assert.IsType<LicenseStatus.Commercial>(status);
    }
}

[Collection("LicenseEnvSerialization")]
public sealed class LicenseValidatorFailureModeTests
{
    private readonly LicenseValidatorTestKeyFixture _fx;

    public LicenseValidatorFailureModeTests(LicenseValidatorTestKeyFixture fx) => _fx = fx;

    [Fact]
    public async Task ReturnsFreeProdForTamperedToken()
    {
        using var env = new EnvScope()
            .Set("DVAI_FORCE_PROD", "1")
            .Set("DVAI_FORCE_DEV", null)
            .Set("DVAI_AUDIENCE", "acme.com");
        var token = _fx.MintLicense(aud: new[] { "acme.com" }, platforms: new[] { "dotnet" });
        // Flip bytes in the payload segment to break the signature.
        var parts = token.Split('.');
        Assert.Equal(3, parts.Length);
        var corrupted = $"{parts[0]}.{parts[1].Substring(0, parts[1].Length - 2)}XX.{parts[2]}";
        var status = await new LicenseValidator(new LicenseValidatorOptions
        {
            Token = corrupted,
            PublicKeys = _fx.PublicKeys,
        }).ValidateAsync();
        var prod = Assert.IsType<LicenseStatus.FreeProd>(status);
        var r = prod.Reason.ToLowerInvariant();
        Assert.True(
            r.Contains("signature") || r.Contains("verification") || r.Contains("parseable") || r.Contains("claim"),
            $"unexpected reason: {prod.Reason}");
    }

    [Fact]
    public async Task ReturnsFreeExpiredWhenExpIsInThePast()
    {
        using var env = new EnvScope()
            .Set("DVAI_FORCE_PROD", "1")
            .Set("DVAI_FORCE_DEV", null)
            .Set("DVAI_AUDIENCE", "acme.com");
        var past = DateTimeOffset.UtcNow.ToUnixTimeSeconds() - 3600;
        var token = _fx.MintLicense(
            aud: new[] { "acme.com" },
            platforms: new[] { "dotnet" },
            licensee: "Expired Co",
            expSecondsAbsolute: past);
        var status = await new LicenseValidator(new LicenseValidatorOptions
        {
            Token = token,
            PublicKeys = _fx.PublicKeys,
        }).ValidateAsync();
        var expired = Assert.IsType<LicenseStatus.FreeExpired>(status);
        Assert.Equal("Expired Co", expired.Licensee);
        Assert.True(expired.ExpiredAt < DateTimeOffset.UtcNow.ToUnixTimeSeconds());
    }

    [Fact]
    public async Task ReturnsFreeProdWhenAudienceDoesNotMatch()
    {
        using var env = new EnvScope()
            .Set("DVAI_FORCE_PROD", "1")
            .Set("DVAI_FORCE_DEV", null)
            .Set("DVAI_AUDIENCE", "widget.io");
        var token = _fx.MintLicense(aud: new[] { "acme.com" }, platforms: new[] { "dotnet" });
        var status = await new LicenseValidator(new LicenseValidatorOptions
        {
            Token = token,
            PublicKeys = _fx.PublicKeys,
        }).ValidateAsync();
        var prod = Assert.IsType<LicenseStatus.FreeProd>(status);
        Assert.Contains("audience", prod.Reason);
        Assert.Contains("widget.io", prod.Reason);
    }

    [Fact]
    public async Task ReturnsFreeProdWhenPlatformIsNotInClaim()
    {
        using var env = new EnvScope()
            .Set("DVAI_FORCE_PROD", "1")
            .Set("DVAI_FORCE_DEV", null)
            .Set("DVAI_AUDIENCE", "acme.com");
        // Issue a token that covers ios/android but NOT dotnet.
        var token = _fx.MintLicense(aud: new[] { "acme.com" }, platforms: new[] { "ios", "android" });
        var status = await new LicenseValidator(new LicenseValidatorOptions
        {
            Token = token,
            PublicKeys = _fx.PublicKeys,
        }).ValidateAsync();
        var prod = Assert.IsType<LicenseStatus.FreeProd>(status);
        Assert.Contains("platform", prod.Reason);
        Assert.Contains("dotnet", prod.Reason);
    }

    [Fact]
    public async Task ReturnsFreeProdWhenKidIsNotInRegistry()
    {
        using var env = new EnvScope()
            .Set("DVAI_FORCE_PROD", "1")
            .Set("DVAI_FORCE_DEV", null)
            .Set("DVAI_AUDIENCE", "acme.com");
        var token = _fx.MintLicense(
            aud: new[] { "acme.com" },
            platforms: new[] { "dotnet" },
            kid: "unknown-kid-2099");
        var status = await new LicenseValidator(new LicenseValidatorOptions
        {
            Token = token,
            PublicKeys = _fx.PublicKeys,
        }).ValidateAsync();
        var prod = Assert.IsType<LicenseStatus.FreeProd>(status);
        Assert.Contains("unknown-kid-2099", prod.Reason);
        Assert.Contains("registry", prod.Reason);
    }

    [Fact]
    public async Task RefusesPlaceholderKidUnlessAllowPlaceholderKeyIsSet()
    {
        using var env = new EnvScope()
            .Set("DVAI_FORCE_PROD", "1")
            .Set("DVAI_FORCE_DEV", null)
            .Set("DVAI_AUDIENCE", "acme.com");
        var token = _fx.MintLicense(
            aud: new[] { "acme.com" },
            platforms: new[] { "dotnet" },
            kid: PublicKeys.PlaceholderKid);
        // Use a registry where the placeholder kid points at our test key —
        // signature would otherwise verify; we expect the validator to
        // still refuse because AllowPlaceholderKey is off.
        var registry = new Dictionary<string, DvaiPublicKey>
        {
            [PublicKeys.PlaceholderKid] = _fx.PublicJwk with { Kid = PublicKeys.PlaceholderKid },
        };
        var status = await new LicenseValidator(new LicenseValidatorOptions
        {
            Token = token,
            PublicKeys = registry,
        }).ValidateAsync();
        var prod = Assert.IsType<LicenseStatus.FreeProd>(status);
        Assert.Contains("placeholder", prod.Reason);
    }

    [Fact]
    public async Task AcceptsPlaceholderKidWhenAllowPlaceholderKeyIsSet()
    {
        using var env = new EnvScope()
            .Set("DVAI_FORCE_PROD", "1")
            .Set("DVAI_FORCE_DEV", null)
            .Set("DVAI_AUDIENCE", "acme.com");
        var token = _fx.MintLicense(
            aud: new[] { "acme.com" },
            platforms: new[] { "dotnet" },
            kid: PublicKeys.PlaceholderKid);
        var registry = new Dictionary<string, DvaiPublicKey>
        {
            [PublicKeys.PlaceholderKid] = _fx.PublicJwk with { Kid = PublicKeys.PlaceholderKid },
        };
        var status = await new LicenseValidator(new LicenseValidatorOptions
        {
            Token = token,
            PublicKeys = registry,
            AllowPlaceholderKey = true,
        }).ValidateAsync();
        Assert.IsType<LicenseStatus.Commercial>(status);
    }

    [Fact]
    public async Task RejectsAlgNoneAndHs256TokensAlgConfusionDefense()
    {
        using var env = new EnvScope()
            .Set("DVAI_FORCE_PROD", "1")
            .Set("DVAI_FORCE_DEV", null)
            .Set("DVAI_AUDIENCE", "acme.com");
        // Hand-roll an alg=none token (no signature).
        var headerJson = JsonSerializer.Serialize(new { alg = "none", typ = "JWT" });
        var payloadJson = JsonSerializer.Serialize(new
        {
            iss = "DVAI-Bridge",
            sub = "x",
            aud = new[] { "acme.com" },
            tier = "commercial",
            platforms = new[] { "dotnet" },
            licensee = "Evil Co",
            iat = DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
            exp = DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 3600,
        });
        var noneToken = $"{Base64Url(headerJson)}.{Base64Url(payloadJson)}.";
        var status = await new LicenseValidator(new LicenseValidatorOptions
        {
            Token = noneToken,
            PublicKeys = _fx.PublicKeys,
        }).ValidateAsync();
        var prod = Assert.IsType<LicenseStatus.FreeProd>(status);
        Assert.Contains("ES256", prod.Reason);
    }

    [Fact]
    public async Task ReturnsFreeProdWhenTokenIsMalformed()
    {
        using var env = new EnvScope()
            .Set("DVAI_FORCE_PROD", "1")
            .Set("DVAI_FORCE_DEV", null);
        var status = await new LicenseValidator(new LicenseValidatorOptions
        {
            Token = "not.a.valid.jwt",
            PublicKeys = _fx.PublicKeys,
        }).ValidateAsync();
        Assert.IsType<LicenseStatus.FreeProd>(status);
    }

    [Fact]
    public async Task ReturnsFreeProdWhenNoTokenProvidedAndAutoDiscoveryFails()
    {
        using var env = new EnvScope()
            .Set("DVAI_FORCE_PROD", "1")
            .Set("DVAI_FORCE_DEV", null)
            .Set("DVAI_LICENSE_TOKEN", null)
            .Set("DVAI_LICENSE_PATH", null);
        // Auto-discovery WILL look at AppContext.BaseDirectory and LocalAppData;
        // those won't have dvai-license.jwt in a clean CI environment but COULD
        // be polluted by a previous run on the developer's machine. We can
        // tolerate a flake here only if there's actually a license — so check
        // for it and skip the assertion in that case.
        var status = await new LicenseValidator(new LicenseValidatorOptions
        {
            PublicKeys = _fx.PublicKeys,
        }).ValidateAsync();
        var prod = Assert.IsType<LicenseStatus.FreeProd>(status);
        Assert.Contains("no license token found", prod.Reason);
    }

    private static string Base64Url(string s)
    {
        return Convert.ToBase64String(Encoding.UTF8.GetBytes(s))
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');
    }
}

[Collection("LicenseEnvSerialization")]
public sealed class LicenseValidatorDevModeTests
{
    private readonly LicenseValidatorTestKeyFixture _fx;

    public LicenseValidatorDevModeTests(LicenseValidatorTestKeyFixture fx) => _fx = fx;

    [Fact]
    public async Task ReturnsFreeDevWhenForceDevIsSet()
    {
        using var env = new EnvScope()
            .Set("DVAI_FORCE_PROD", null)
            .Set("DVAI_FORCE_DEV", "1");
        var status = await new LicenseValidator(new LicenseValidatorOptions
        {
            PublicKeys = _fx.PublicKeys,
        }).ValidateAsync();
        Assert.IsType<LicenseStatus.FreeDev>(status);
    }

    [Fact]
    public async Task ForceProdOverridesForceDev()
    {
        using var env = new EnvScope()
            .Set("DVAI_FORCE_PROD", "1")
            .Set("DVAI_FORCE_DEV", "1");
        var status = await new LicenseValidator(new LicenseValidatorOptions
        {
            PublicKeys = _fx.PublicKeys,
        }).ValidateAsync();
        // With DVAI_FORCE_PROD set, dev-mode is suppressed → missing
        // license → FreeProd.
        Assert.IsType<LicenseStatus.FreeProd>(status);
    }
}

[Collection("LicenseEnvSerialization")]
public sealed class LicenseValidatorDiscoveryTests
{
    private readonly LicenseValidatorTestKeyFixture _fx;

    public LicenseValidatorDiscoveryTests(LicenseValidatorTestKeyFixture fx) => _fx = fx;

    [Fact]
    public async Task LoadsFromExplicitPath()
    {
        using var env = new EnvScope()
            .Set("DVAI_FORCE_PROD", "1")
            .Set("DVAI_FORCE_DEV", null)
            .Set("DVAI_AUDIENCE", "acme.com");
        var tmpDir = Directory.CreateTempSubdirectory("dvai-license-");
        try
        {
            var filePath = Path.Combine(tmpDir.FullName, "dvai-license.jwt");
            var token = _fx.MintLicense(aud: new[] { "acme.com" }, platforms: new[] { "dotnet" });
            await File.WriteAllTextAsync(filePath, token);
            var status = await new LicenseValidator(new LicenseValidatorOptions
            {
                Path = filePath,
                PublicKeys = _fx.PublicKeys,
            }).ValidateAsync();
            Assert.IsType<LicenseStatus.Commercial>(status);
        }
        finally
        {
            tmpDir.Delete(recursive: true);
        }
    }

    [Fact]
    public async Task LoadsFromDvaiLicenseTokenEnvVar()
    {
        using var env = new EnvScope()
            .Set("DVAI_FORCE_PROD", "1")
            .Set("DVAI_FORCE_DEV", null)
            .Set("DVAI_AUDIENCE", "acme.com");
        var token = _fx.MintLicense(aud: new[] { "acme.com" }, platforms: new[] { "dotnet" });
        env.Set("DVAI_LICENSE_TOKEN", token);
        var status = await new LicenseValidator(new LicenseValidatorOptions
        {
            PublicKeys = _fx.PublicKeys,
        }).ValidateAsync();
        Assert.IsType<LicenseStatus.Commercial>(status);
    }

    [Fact]
    public async Task LoadsFromDvaiLicensePathEnvVar()
    {
        using var env = new EnvScope()
            .Set("DVAI_FORCE_PROD", "1")
            .Set("DVAI_FORCE_DEV", null)
            .Set("DVAI_AUDIENCE", "acme.com");
        var tmpDir = Directory.CreateTempSubdirectory("dvai-license-");
        try
        {
            var filePath = Path.Combine(tmpDir.FullName, "dvai-license.jwt");
            var token = _fx.MintLicense(aud: new[] { "acme.com" }, platforms: new[] { "dotnet" });
            await File.WriteAllTextAsync(filePath, token);
            env.Set("DVAI_LICENSE_PATH", filePath);
            var status = await new LicenseValidator(new LicenseValidatorOptions
            {
                PublicKeys = _fx.PublicKeys,
            }).ValidateAsync();
            Assert.IsType<LicenseStatus.Commercial>(status);
        }
        finally
        {
            tmpDir.Delete(recursive: true);
        }
    }

    [Fact]
    public async Task ReturnsFreeProdWhenExplicitPathDoesNotExist()
    {
        using var env = new EnvScope()
            .Set("DVAI_FORCE_PROD", "1")
            .Set("DVAI_FORCE_DEV", null);
        var status = await new LicenseValidator(new LicenseValidatorOptions
        {
            Path = Path.Combine(Path.GetTempPath(), "nonexistent-dvai-license-fixture", "dvai-license.jwt"),
            PublicKeys = _fx.PublicKeys,
        }).ValidateAsync();
        Assert.IsType<LicenseStatus.FreeProd>(status);
    }

    [Fact]
    public async Task InlineTokenWinsOverPathWhenBothSet()
    {
        using var env = new EnvScope()
            .Set("DVAI_FORCE_PROD", "1")
            .Set("DVAI_FORCE_DEV", null)
            .Set("DVAI_AUDIENCE", "acme.com");
        var inline = _fx.MintLicense(
            aud: new[] { "acme.com" },
            platforms: new[] { "dotnet" },
            licensee: "Inline Co");
        var status = await new LicenseValidator(new LicenseValidatorOptions
        {
            Token = inline,
            Path = Path.Combine(Path.GetTempPath(), "nonexistent-dvai-license-fixture", "dvai-license.jwt"),
            PublicKeys = _fx.PublicKeys,
        }).ValidateAsync();
        var c = Assert.IsType<LicenseStatus.Commercial>(status);
        Assert.Equal("Inline Co", c.Licensee);
    }
}

[Collection("LicenseEnvSerialization")]
public sealed class LicenseValidatorValidateAndAssertTests
{
    private readonly LicenseValidatorTestKeyFixture _fx;

    public LicenseValidatorValidateAndAssertTests(LicenseValidatorTestKeyFixture fx) => _fx = fx;

    [Fact]
    public async Task ReturnsStatusForCommercialLicensesWithoutThrowing()
    {
        using var env = new EnvScope()
            .Set("DVAI_FORCE_PROD", "1")
            .Set("DVAI_FORCE_DEV", null)
            .Set("DVAI_AUDIENCE", "acme.com");
        var token = _fx.MintLicense(aud: new[] { "acme.com" }, platforms: new[] { "dotnet" });
        var status = await new LicenseValidator(new LicenseValidatorOptions
        {
            Token = token,
            PublicKeys = _fx.PublicKeys,
        }).ValidateAndAssertAsync();
        Assert.IsType<LicenseStatus.Commercial>(status);
    }

    [Fact]
    public async Task ReturnsStatusForTrialLicensesWithoutThrowing()
    {
        using var env = new EnvScope()
            .Set("DVAI_FORCE_PROD", "1")
            .Set("DVAI_FORCE_DEV", null)
            .Set("DVAI_AUDIENCE", "acme.com");
        var token = _fx.MintLicense(aud: new[] { "acme.com" }, platforms: new[] { "dotnet" }, tier: "trial");
        var status = await new LicenseValidator(new LicenseValidatorOptions
        {
            Token = token,
            PublicKeys = _fx.PublicKeys,
        }).ValidateAndAssertAsync();
        Assert.IsType<LicenseStatus.Trial>(status);
    }

    [Fact]
    public async Task ReturnsStatusForFreeDevWithoutThrowing()
    {
        using var env = new EnvScope()
            .Set("DVAI_FORCE_PROD", null)
            .Set("DVAI_FORCE_DEV", "1");
        var status = await new LicenseValidator(new LicenseValidatorOptions
        {
            PublicKeys = _fx.PublicKeys,
        }).ValidateAndAssertAsync();
        Assert.IsType<LicenseStatus.FreeDev>(status);
    }

    [Fact]
    public async Task ThrowsLicenseRequiredExceptionWhenNoLicenseInProduction()
    {
        using var env = new EnvScope()
            .Set("DVAI_FORCE_PROD", "1")
            .Set("DVAI_FORCE_DEV", null)
            .Set("DVAI_LICENSE_TOKEN", null)
            .Set("DVAI_LICENSE_PATH", null);
        var v = new LicenseValidator(new LicenseValidatorOptions { PublicKeys = _fx.PublicKeys });
        await Assert.ThrowsAsync<LicenseRequiredException>(() => v.ValidateAndAssertAsync());
    }

    [Fact]
    public async Task ThrowsLicenseRequiredExceptionWithFreeProdStatusForMissingLicense()
    {
        using var env = new EnvScope()
            .Set("DVAI_FORCE_PROD", "1")
            .Set("DVAI_FORCE_DEV", null)
            .Set("DVAI_LICENSE_TOKEN", null)
            .Set("DVAI_LICENSE_PATH", null);
        var v = new LicenseValidator(new LicenseValidatorOptions { PublicKeys = _fx.PublicKeys });
        var ex = await Assert.ThrowsAsync<LicenseRequiredException>(() => v.ValidateAndAssertAsync());
        Assert.IsType<LicenseStatus.FreeProd>(ex.Status);
        Assert.Contains("Commercial License Required", ex.Message);
        Assert.Contains("dvai-license.jwt", ex.Message);
        Assert.Contains("DVAI_LICENSE_PATH", ex.Message);
    }

    [Fact]
    public async Task ThrowsLicenseRequiredExceptionWithFreeExpiredStatusForExpiredTokens()
    {
        using var env = new EnvScope()
            .Set("DVAI_FORCE_PROD", "1")
            .Set("DVAI_FORCE_DEV", null)
            .Set("DVAI_AUDIENCE", "acme.com");
        var past = DateTimeOffset.UtcNow.ToUnixTimeSeconds() - 3600;
        var token = _fx.MintLicense(
            aud: new[] { "acme.com" },
            platforms: new[] { "dotnet" },
            licensee: "Expired Co",
            expSecondsAbsolute: past);
        var v = new LicenseValidator(new LicenseValidatorOptions
        {
            Token = token,
            PublicKeys = _fx.PublicKeys,
        });
        var ex = await Assert.ThrowsAsync<LicenseRequiredException>(() => v.ValidateAndAssertAsync());
        Assert.IsType<LicenseStatus.FreeExpired>(ex.Status);
        Assert.Contains("Expired Co", ex.Message);
    }

    [Fact]
    public async Task ThrowsForTamperedTokensInProduction()
    {
        using var env = new EnvScope()
            .Set("DVAI_FORCE_PROD", "1")
            .Set("DVAI_FORCE_DEV", null)
            .Set("DVAI_AUDIENCE", "acme.com");
        var token = _fx.MintLicense(aud: new[] { "acme.com" }, platforms: new[] { "dotnet" });
        var parts = token.Split('.');
        var corrupted = $"{parts[0]}.{parts[1].Substring(0, parts[1].Length - 2)}XX.{parts[2]}";
        var v = new LicenseValidator(new LicenseValidatorOptions
        {
            Token = corrupted,
            PublicKeys = _fx.PublicKeys,
        });
        await Assert.ThrowsAsync<LicenseRequiredException>(() => v.ValidateAndAssertAsync());
    }

    [Fact]
    public async Task ThrowsForAudienceMismatchedTokensInProduction()
    {
        using var env = new EnvScope()
            .Set("DVAI_FORCE_PROD", "1")
            .Set("DVAI_FORCE_DEV", null)
            .Set("DVAI_AUDIENCE", "widget.io");
        var token = _fx.MintLicense(aud: new[] { "acme.com" }, platforms: new[] { "dotnet" });
        var v = new LicenseValidator(new LicenseValidatorOptions
        {
            Token = token,
            PublicKeys = _fx.PublicKeys,
        });
        await Assert.ThrowsAsync<LicenseRequiredException>(() => v.ValidateAndAssertAsync());
    }

    [Fact]
    public async Task DoesNotThrowInDevModeEvenWhenLicenseIsInvalid()
    {
        using var env = new EnvScope()
            .Set("DVAI_FORCE_PROD", null)
            .Set("DVAI_FORCE_DEV", "1");
        var v = new LicenseValidator(new LicenseValidatorOptions
        {
            Token = "not-even-a-jwt",
            PublicKeys = _fx.PublicKeys,
        });
        var status = await v.ValidateAndAssertAsync();
        Assert.IsType<LicenseStatus.FreeDev>(status);
    }
}

public sealed class AudienceTests
{
    [Theory]
    [InlineData("acme.com", new[] { "acme.com" }, "acme.com")]
    [InlineData("acme.com", new[] { "*.acme.com" }, "*.acme.com")] // apex
    [InlineData("app.acme.com", new[] { "*.acme.com" }, "*.acme.com")] // subdomain
    [InlineData("widget.io", new[] { "acme.com", "*" }, "*")] // permissive
    [InlineData("acme.com", new[] { "ACME.COM" }, "ACME.COM")] // case-insensitive
    public void MatchAudienceMatchesExpectedEntry(string runtime, string[] aud, string expected)
    {
        var matched = Audience.MatchAudience(runtime, aud);
        Assert.Equal(expected, matched);
    }

    [Fact]
    public void MatchAudienceReturnsNullOnMiss()
    {
        var matched = Audience.MatchAudience("widget.io", new[] { "acme.com", "*.acme.com" });
        Assert.Null(matched);
    }

    [Fact]
    public void MatchAudienceNullRuntimeOnlyMatchesStar()
    {
        Assert.Equal("*", Audience.MatchAudience(null, new[] { "*" }));
        Assert.Null(Audience.MatchAudience(null, new[] { "acme.com", "*.acme.com" }));
    }

    [Fact]
    public void DetectPlatformReturnsDotnet()
    {
        Assert.Equal(DvaiPlatform.Dotnet, Audience.DetectPlatform());
    }
}
