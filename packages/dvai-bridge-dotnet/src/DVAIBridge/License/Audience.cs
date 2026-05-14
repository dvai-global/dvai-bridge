// <copyright file="Audience.cs" company="Deep Voice AI">
//   Copyright (c) 2026 Deep Voice AI. All rights reserved.
// </copyright>

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Reflection;

namespace DVAIBridge.License;

/// <summary>
/// Runtime audience + platform + dev-mode detection for the .NET SDK.
/// Mirrors the semantics of the JS-side <c>audience.ts</c> using .NET
/// platform APIs.
/// </summary>
public static class Audience
{
    /// <summary>
    /// Detect the current SDK platform identifier. Always returns
    /// <see cref="DvaiPlatform.Dotnet"/>. MAUI builds running on iOS /
    /// Android still report <c>.Dotnet</c> because that's the SDK
    /// identity from the license's perspective — the underlying
    /// platform doesn't matter for the license check.
    /// </summary>
    /// <returns>The platform identifier.</returns>
    public static DvaiPlatform DetectPlatform() => DvaiPlatform.Dotnet;

    /// <summary>
    /// Returns <c>true</c> when this assembly is a Debug build. The
    /// underlying <c>#if DEBUG</c> compile flag is captured at build
    /// time and exposed at runtime via this property so the validator
    /// (which is not <c>#if DEBUG</c>-conditional itself) can read it.
    /// </summary>
    public static bool IsDebugBuild =>
#if DEBUG
        true;
#else
        false;
#endif

    /// <summary>
    /// Detect the current audience string the license must bind to.
    /// Returns <c>null</c> when no determinable audience exists — the
    /// validator handles <c>null</c> by accepting any aud entry, since
    /// binding enforcement requires a concrete runtime identifier.
    ///
    /// <para>Resolution order:</para>
    /// <list type="number">
    /// <item>Operator override via <c>DVAI_AUDIENCE</c> env var.</item>
    /// <item><see cref="Assembly.GetEntryAssembly"/> name (the runtime audience for most apps).</item>
    /// <item><see cref="AppDomain.FriendlyName"/> fallback (test runners, in-process hosts).</item>
    /// </list>
    /// </summary>
    /// <returns>The audience string, or <c>null</c> if none could be determined.</returns>
    public static string? DetectAudience()
    {
        var envOverride = Environment.GetEnvironmentVariable("DVAI_AUDIENCE");
        if (!string.IsNullOrEmpty(envOverride))
        {
            return envOverride;
        }

        var entry = Assembly.GetEntryAssembly()?.GetName().Name;
        if (!string.IsNullOrEmpty(entry))
        {
            return entry;
        }

        var friendly = AppDomain.CurrentDomain.FriendlyName;
        return string.IsNullOrEmpty(friendly) ? null : friendly;
    }

    /// <summary>
    /// Result of dev-mode detection. Mirrors the JS-side
    /// <c>{ isDev, reason }</c> tuple.
    /// </summary>
    /// <param name="IsDev">True iff the SDK should bypass license enforcement.</param>
    /// <param name="Reason">Human-readable reason for the decision.</param>
    public sealed record DevModeResult(bool IsDev, string Reason);

    /// <summary>
    /// Detect whether the SDK is running in a developer environment
    /// where license enforcement should be bypassed. The bypass list
    /// is intentionally generous: blocking a developer mid-<c>dotnet run</c>
    /// with a license-not-found error would be hostile.
    ///
    /// <para>Resolution order (first match wins):</para>
    /// <list type="number">
    /// <item><c>DVAI_FORCE_PROD=1</c> → force prod (overrides everything else).</item>
    /// <item><c>DVAI_FORCE_DEV=1</c> → force dev.</item>
    /// <item><see cref="Debugger.IsAttached"/> → dev.</item>
    /// <item><see cref="IsDebugBuild"/> → dev.</item>
    /// <item>Otherwise → production, license required.</item>
    /// </list>
    /// </summary>
    /// <returns>The detection result.</returns>
    public static DevModeResult DetectDevMode()
    {
        // 1. Explicit env-var override. DVAI_FORCE_PROD wins over everything.
        if (IsEnvTruthy("DVAI_FORCE_PROD"))
        {
            return new DevModeResult(false, "DVAI_FORCE_PROD set");
        }

        if (IsEnvTruthy("DVAI_FORCE_DEV"))
        {
            return new DevModeResult(true, "DVAI_FORCE_DEV set");
        }

        // 2. Debugger attached — clearly a developer iteration loop.
        if (Debugger.IsAttached)
        {
            return new DevModeResult(true, "debugger attached");
        }

        // 3. Debug build flag.
        if (IsDebugBuild)
        {
            return new DevModeResult(true, "DEBUG build");
        }

        return new DevModeResult(false, "production-class environment");
    }

    /// <summary>
    /// Decide whether a license-payload <c>aud</c> entry matches the
    /// current runtime audience. Supports exact match and
    /// <c>*.example.com</c> wildcard matching for subdomain binding.
    /// Returns the matched <c>aud</c> pattern on success so it can be
    /// recorded for audit, or <c>null</c> on miss.
    ///
    /// <para>Match rules:</para>
    /// <list type="bullet">
    /// <item><c>"foo"</c> matches <c>"foo"</c> exactly.</item>
    /// <item><c>"*.example.com"</c> matches <c>"example.com"</c> AND any <c>"&lt;sub&gt;.example.com"</c>.</item>
    /// <item><c>"*"</c> matches any non-empty audience (intentionally permissive).</item>
    /// </list>
    ///
    /// <para>
    /// A runtime audience of <c>null</c> matches <c>"*"</c> only — a
    /// .NET deployment without a determinable audience can activate
    /// "any-domain" licenses but not domain-bound ones. Operators that
    /// want stricter binding set <c>DVAI_AUDIENCE</c> explicitly.
    /// </para>
    /// </summary>
    /// <param name="runtimeAudience">The detected runtime audience, or <c>null</c>.</param>
    /// <param name="audClaim">The <c>aud</c> claim from the license payload.</param>
    /// <returns>The matching <c>aud</c> entry, or <c>null</c> on miss.</returns>
    public static string? MatchAudience(string? runtimeAudience, IReadOnlyList<string> audClaim)
    {
        if (runtimeAudience is null)
        {
            foreach (var pattern in audClaim)
            {
                if (pattern == "*")
                {
                    return "*";
                }
            }

            return null;
        }

        var runtime = runtimeAudience.ToLowerInvariant();
        foreach (var pattern in audClaim)
        {
            var p = pattern.ToLowerInvariant();
            if (p == "*")
            {
                return pattern; // permissive wildcard
            }

            if (p == runtime)
            {
                return pattern; // exact match
            }

            if (p.StartsWith("*.", StringComparison.Ordinal))
            {
                var suffix = p.Substring(2);
                if (runtime == suffix || runtime.EndsWith("." + suffix, StringComparison.Ordinal))
                {
                    return pattern;
                }
            }
        }

        return null;
    }

    private static bool IsEnvTruthy(string name)
    {
        var v = Environment.GetEnvironmentVariable(name);
        return v == "1" || string.Equals(v, "true", StringComparison.OrdinalIgnoreCase);
    }
}
