// <copyright file="Discovery.cs" company="Deep Voice AI">
//   Copyright (c) 2026 Deep Voice AI. All rights reserved.
// </copyright>

using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

namespace DVAIBridge.License;

/// <summary>
/// Options that drive <see cref="Discovery.DiscoverLicenseTokenAsync"/>.
/// Mirror the JS-side <c>LicenseDiscoveryOptions</c>.
/// </summary>
public sealed record LicenseDiscoveryOptions
{
    /// <summary>
    /// Pre-loaded JWT string (skips all filesystem lookups). Wins over
    /// every other source.
    /// </summary>
    public string? Token { get; init; }

    /// <summary>
    /// Explicit path to load the token from. Wins over env vars and
    /// auto-discovery, but loses to <see cref="Token"/>. A missing path
    /// is a real miss (no silent fall-through to env / auto-discovery).
    /// </summary>
    public string? Path { get; init; }
}

/// <summary>
/// Result of a successful token discovery — both the JWT string and a
/// short description of where it came from (used for diagnostic logging).
/// </summary>
/// <param name="Token">The raw JWT string.</param>
/// <param name="Source">Human-readable description of where the token came from.</param>
public sealed record DiscoveredToken(string Token, string Source);

/// <summary>
/// License-file discovery for the .NET SDK.
///
/// <para>Reads the license JWT from (in priority order):</para>
/// <list type="number">
/// <item>Explicit <see cref="LicenseDiscoveryOptions.Token"/> — inline JWT.</item>
/// <item>Explicit <see cref="LicenseDiscoveryOptions.Path"/> — file path.</item>
/// <item><c>DVAI_LICENSE_PATH</c> env var — file path.</item>
/// <item><c>DVAI_LICENSE_TOKEN</c> env var — inline JWT.</item>
/// <item><c>Path.Combine(AppContext.BaseDirectory, "dvai-license.jwt")</c> — alongside the executable.</item>
/// <item><c>Path.Combine(LocalAppData, "dvai-bridge", "dvai-license.jwt")</c> — per-user AppData.</item>
/// </list>
/// </summary>
public static class Discovery
{
    /// <summary>
    /// Default filename the SDK looks for. Matches the JS-side
    /// <c>DEFAULT_LICENSE_FILENAME</c>.
    /// </summary>
    public const string DefaultLicenseFilename = "dvai-license.jwt";

    /// <summary>
    /// Best-effort load of a license JWT. Returns the raw token string
    /// on success or <c>null</c> on miss. Errors during loading collapse
    /// to <c>null</c> — the validator's responsibility is to handle the
    /// no-license case gracefully.
    /// </summary>
    /// <param name="opts">Discovery options.</param>
    /// <param name="ct">Cancellation token for file I/O.</param>
    /// <returns>The discovered token + source, or <c>null</c> on miss.</returns>
    public static async Task<DiscoveredToken?> DiscoverLicenseTokenAsync(
        LicenseDiscoveryOptions? opts = null,
        CancellationToken ct = default)
    {
        opts ??= new LicenseDiscoveryOptions();

        // 1. Explicit token wins.
        if (!string.IsNullOrEmpty(opts.Token))
        {
            return new DiscoveredToken(opts.Token!.Trim(), "options.Token");
        }

        // 2. Explicit path (config option) — a real miss here does NOT
        //    fall through to env-var / auto-discovery (matches JS-side
        //    semantics: an operator who specifies a path expects it to
        //    succeed or fail loudly).
        if (!string.IsNullOrEmpty(opts.Path))
        {
            var loaded = await TryLoadFromPathAsync(opts.Path!, ct).ConfigureAwait(false);
            return loaded is null ? null : new DiscoveredToken(loaded, opts.Path!);
        }

        // 3. Env-var path.
        var envPath = Environment.GetEnvironmentVariable("DVAI_LICENSE_PATH");
        if (!string.IsNullOrEmpty(envPath))
        {
            var loaded = await TryLoadFromPathAsync(envPath, ct).ConfigureAwait(false);
            if (loaded is not null)
            {
                return new DiscoveredToken(loaded, $"DVAI_LICENSE_PATH={envPath}");
            }
        }

        // 4. Env-var inline token (alternative to file for containers / CI).
        var envToken = Environment.GetEnvironmentVariable("DVAI_LICENSE_TOKEN");
        if (!string.IsNullOrEmpty(envToken))
        {
            return new DiscoveredToken(envToken!.Trim(), "DVAI_LICENSE_TOKEN env var");
        }

        // 5. Default location: alongside the executable.
        var baseDirCandidate = Path.Combine(AppContext.BaseDirectory, DefaultLicenseFilename);
        var baseDirLoaded = await TryLoadFromPathAsync(baseDirCandidate, ct).ConfigureAwait(false);
        if (baseDirLoaded is not null)
        {
            return new DiscoveredToken(baseDirLoaded, baseDirCandidate);
        }

        // 6. Default location: per-user AppData.
        var appDataDir = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (!string.IsNullOrEmpty(appDataDir))
        {
            var appDataCandidate = Path.Combine(appDataDir, "dvai-bridge", DefaultLicenseFilename);
            var appDataLoaded = await TryLoadFromPathAsync(appDataCandidate, ct).ConfigureAwait(false);
            if (appDataLoaded is not null)
            {
                return new DiscoveredToken(appDataLoaded, appDataCandidate);
            }
        }

        return null;
    }

    private static async Task<string?> TryLoadFromPathAsync(string path, CancellationToken ct)
    {
        try
        {
            if (!File.Exists(path))
            {
                return null;
            }

            var contents = await File.ReadAllTextAsync(path, ct).ConfigureAwait(false);
            var trimmed = contents.Trim();
            return trimmed.Length == 0 ? null : trimmed;
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch
        {
            // Any other I/O failure (permissions, race) collapses to null —
            // the validator's job is to handle the missing-license case.
            return null;
        }
    }
}
