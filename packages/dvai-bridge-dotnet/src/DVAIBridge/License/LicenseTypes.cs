// <copyright file="LicenseTypes.cs" company="Deep Voice AI">
//   Copyright (c) 2026 Deep Voice AI. All rights reserved.
// </copyright>

using System;
using System.Collections.Generic;

namespace DVAIBridge.License;

/// <summary>
/// Platform identifiers the SDK recognises in license <c>platforms</c>
/// claims. Mirrors the <c>DvaiPlatform</c> string union in the JS-side
/// <c>types.ts</c>.
/// </summary>
public enum DvaiPlatform
{
    /// <summary>Browser / Vite / Webpack runtime.</summary>
    Web,

    /// <summary>Node.js runtime.</summary>
    Node,

    /// <summary>Native iOS SDK.</summary>
    IOS,

    /// <summary>Native Android SDK.</summary>
    Android,

    /// <summary>.NET SDK (MAUI / Avalonia / WinUI / desktop).</summary>
    Dotnet,

    /// <summary>Flutter binding.</summary>
    Flutter,

    /// <summary>React Native binding.</summary>
    ReactNative,

    /// <summary>Capacitor binding.</summary>
    Capacitor,
}

/// <summary>
/// JWT-payload shape we issue (subset; extra claims tolerated). Mirrors
/// the JS-side <c>DvaiLicensePayload</c> interface.
/// </summary>
/// <param name="Iss">Standard JWT issuer. Must be <c>"DVAI-Bridge"</c>.</param>
/// <param name="Sub">Standard subject — our internal license id. Surfaced in audit logs.</param>
/// <param name="Aud">
/// Audience binding — array of domains and/or bundle ids permitted to
/// activate this license. Each entry is either an exact string match
/// (e.g. <c>"com.acme.app"</c>) or a wildcard subdomain pattern
/// (e.g. <c>"*.acme.com"</c> matches both <c>acme.com</c> and
/// <c>app.acme.com</c>).
/// </param>
/// <param name="Tier">
/// Tier the license grants. <c>"commercial"</c> and <c>"trial"</c> are
/// the live tiers; the validator never produces a <c>"free-*"</c> here
/// (those are computed).
/// </param>
/// <param name="Platforms">
/// Which DVAI-Bridge SDK platforms this license activates. The current
/// runtime platform must appear here for the license to apply.
/// </param>
/// <param name="Licensee">Display name of the licensee, for audit logs.</param>
/// <param name="Iat">Standard JWT issued-at (seconds since Unix epoch).</param>
/// <param name="Exp">Standard JWT expiry (seconds since Unix epoch).</param>
public sealed record DvaiLicensePayload(
    string Iss,
    string Sub,
    IReadOnlyList<string> Aud,
    string Tier,
    IReadOnlyList<DvaiPlatform> Platforms,
    string Licensee,
    long Iat,
    long Exp);

/// <summary>
/// Result of license validation. Discriminated via subclass — pattern
/// match with <c>switch</c>. Mirrors the JS-side <c>LicenseStatus</c>
/// discriminated union: <c>"commercial"</c> / <c>"trial"</c> →
/// premium; everything else → free.
/// </summary>
public abstract record LicenseStatus
{
    private LicenseStatus()
    {
    }

    /// <summary>
    /// Discriminator string mirroring the JS-side <c>kind</c> field for
    /// JSON round-tripping and pattern-matching ergonomics.
    /// </summary>
    public abstract string Kind { get; }

    /// <summary>
    /// Returns <c>true</c> iff the status represents a paid /
    /// unwatermarked tier (<see cref="Commercial"/> or <see cref="Trial"/>).
    /// </summary>
    public bool IsPaidTier => this is Commercial or Trial;

    /// <summary>Successful commercial-tier license.</summary>
    /// <param name="Licensee">Display name of the licensee.</param>
    /// <param name="ExpiresAt">Expiry timestamp (seconds since Unix epoch).</param>
    /// <param name="Platform">Runtime platform that was matched against the token's <c>platforms</c> claim.</param>
    /// <param name="AudienceMatched">The token's <c>aud</c> entry that matched the runtime audience.</param>
    public sealed record Commercial(
        string Licensee,
        long ExpiresAt,
        DvaiPlatform Platform,
        string AudienceMatched) : LicenseStatus
    {
        /// <inheritdoc/>
        public override string Kind => "commercial";
    }

    /// <summary>Successful trial-tier license.</summary>
    /// <param name="Licensee">Display name of the licensee.</param>
    /// <param name="ExpiresAt">Expiry timestamp (seconds since Unix epoch).</param>
    /// <param name="Platform">Runtime platform that was matched against the token's <c>platforms</c> claim.</param>
    /// <param name="AudienceMatched">The token's <c>aud</c> entry that matched the runtime audience.</param>
    public sealed record Trial(
        string Licensee,
        long ExpiresAt,
        DvaiPlatform Platform,
        string AudienceMatched) : LicenseStatus
    {
        /// <inheritdoc/>
        public override string Kind => "trial";
    }

    /// <summary>
    /// Developer-environment bypass — the validator detected dev mode
    /// (debug build, debugger attached, DVAI_FORCE_DEV) and skipped
    /// license enforcement. SDK runs unrestricted, no badge required.
    /// </summary>
    /// <param name="Reason">Why dev mode was detected (for logging).</param>
    public sealed record FreeDev(string Reason) : LicenseStatus
    {
        /// <inheritdoc/>
        public override string Kind => "free-dev";
    }

    /// <summary>
    /// Production deploy with no valid license. SDK falls back to free
    /// tier with attribution badge. The strict
    /// <see cref="LicenseValidator.ValidateAndAssertAsync(System.Threading.CancellationToken)"/>
    /// throws <see cref="LicenseRequiredException"/> for this case.
    /// </summary>
    /// <param name="Reason">Why a license could not be loaded or validated.</param>
    public sealed record FreeProd(string Reason) : LicenseStatus
    {
        /// <inheritdoc/>
        public override string Kind => "free-prod";
    }

    /// <summary>
    /// Had a valid license but <c>exp</c> is past. SDK falls back to
    /// free tier with attribution badge + warning. The strict
    /// <see cref="LicenseValidator.ValidateAndAssertAsync(System.Threading.CancellationToken)"/>
    /// throws <see cref="LicenseRequiredException"/> for this case.
    /// </summary>
    /// <param name="Licensee">Display name of the (expired) licensee.</param>
    /// <param name="ExpiredAt">When the license expired (seconds since Unix epoch).</param>
    public sealed record FreeExpired(
        string Licensee,
        long ExpiredAt) : LicenseStatus
    {
        /// <inheritdoc/>
        public override string Kind => "free-expired";
    }
}

/// <summary>
/// Thrown by
/// <see cref="LicenseValidator.ValidateAndAssertAsync(System.Threading.CancellationToken)"/>
/// (and propagated from
/// <see cref="DVAIBridge.StartAsync(StartOptions, System.Threading.CancellationToken)"/>)
/// when an SDK consumer attempts to run the library in a production
/// context without a valid commercial or trial license.
///
/// <para>
/// The error message is intentionally verbose: it tells the developer
/// exactly which check failed (missing file, expired, audience
/// mismatch, etc.), how to resolve it, and where to put the license
/// file once they have one. This is the front line of the BSL 1.1
/// commercial enforcement story — surface it clearly enough that a
/// developer can unblock themselves without a support ticket.
/// </para>
///
/// <para>
/// The <see cref="Status"/> property carries the underlying
/// <see cref="LicenseStatus"/> so programmatic callers can dispatch on
/// <c>err.Status</c> if they want to handle "expired" differently from
/// "missing".
/// </para>
/// </summary>
public sealed class LicenseRequiredException : Exception
{
    /// <summary>
    /// Initializes a new instance of the <see cref="LicenseRequiredException"/>
    /// class with the developer-facing diagnostic message and the
    /// underlying validator status that triggered the throw.
    /// </summary>
    /// <param name="message">Verbose developer-facing message.</param>
    /// <param name="status">The validator status that triggered the throw.</param>
    public LicenseRequiredException(string message, LicenseStatus status)
        : base(message)
    {
        Status = status;
    }

    /// <summary>Gets the underlying validator status that triggered the throw.</summary>
    public LicenseStatus Status { get; }
}
