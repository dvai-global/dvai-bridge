using System;
using System.Collections.Generic;

namespace DVAIBridge;

/// <summary>
/// Discriminator for the canonical error categories raised by
/// <see cref="DVAIBridgeException"/>. Mirrors the iOS
/// <c>DVAIBridgeError</c> Swift enum and the Android
/// <c>DVAIBridgeError</c> Kotlin sealed class.
/// </summary>
public enum DVAIBridgeErrorKind
{
    /// <summary><c>StartAsync</c> called while a previous start is still bound.</summary>
    AlreadyStarted,

    /// <summary><see cref="StartOptions"/> failed validation (missing path, bad value, …).</summary>
    ConfigurationInvalid,

    /// <summary>The selected backend rejected the model file.</summary>
    ModelLoadFailed,

    /// <summary>The selected backend is not available on this device or under this build configuration.</summary>
    BackendUnavailable,

    /// <summary>Catch-all native error from the backend during steady-state operation.</summary>
    BackendError,

    /// <summary>Downloaded file's sha256 didn't match <see cref="DownloadOptions.Sha256"/>.</summary>
    ChecksumMismatch,

    /// <summary>Network or filesystem failure during model download.</summary>
    DownloadFailed,
}

/// <summary>
/// The canonical exception type raised by every <see cref="DVAIBridge"/>
/// public method. Carries a <see cref="Kind"/> discriminator and an
/// open-ended <see cref="Details"/> dictionary for kind-specific data
/// (e.g. <c>baseUrl</c> for <see cref="DVAIBridgeErrorKind.AlreadyStarted"/>,
/// <c>expected</c> + <c>got</c> for <see cref="DVAIBridgeErrorKind.ChecksumMismatch"/>).
/// </summary>
/// <remarks>
/// Constructed only via the static factories — direct construction is
/// blocked. The factories ensure the <see cref="Details"/> dictionary
/// is populated consistently with the iOS and Android SDK error shapes.
/// </remarks>
public sealed class DVAIBridgeException : Exception
{
    /// <summary>The category of error.</summary>
    public DVAIBridgeErrorKind Kind { get; }

    /// <summary>Kind-specific details. Read-only.</summary>
    public IReadOnlyDictionary<string, object?> Details { get; }

    private DVAIBridgeException(
        DVAIBridgeErrorKind kind,
        string message,
        IReadOnlyDictionary<string, object?> details,
        Exception? innerException = null)
        : base(message, innerException)
    {
        Kind = kind;
        Details = details;
    }

    /// <summary><see cref="DVAIBridgeErrorKind.AlreadyStarted"/> factory.</summary>
    public static DVAIBridgeException AlreadyStarted(BackendKind backend, string baseUrl) =>
        new(
            DVAIBridgeErrorKind.AlreadyStarted,
            $"DVAIBridge already started: backend={backend}, baseUrl={baseUrl}",
            new Dictionary<string, object?>
            {
                ["backend"] = backend,
                ["baseUrl"] = baseUrl,
            });

    /// <summary><see cref="DVAIBridgeErrorKind.ConfigurationInvalid"/> factory.</summary>
    public static DVAIBridgeException ConfigurationInvalid(string reason) =>
        new(
            DVAIBridgeErrorKind.ConfigurationInvalid,
            $"DVAIBridge configuration invalid: {reason}",
            new Dictionary<string, object?>
            {
                ["reason"] = reason,
            });

    /// <summary><see cref="DVAIBridgeErrorKind.ModelLoadFailed"/> factory.</summary>
    public static DVAIBridgeException ModelLoadFailed(string reason) =>
        new(
            DVAIBridgeErrorKind.ModelLoadFailed,
            $"DVAIBridge model load failed: {reason}",
            new Dictionary<string, object?>
            {
                ["reason"] = reason,
            });

    /// <summary><see cref="DVAIBridgeErrorKind.BackendUnavailable"/> factory.</summary>
    public static DVAIBridgeException BackendUnavailable(BackendKind backend, string reason) =>
        new(
            DVAIBridgeErrorKind.BackendUnavailable,
            $"DVAIBridge backend {backend} unavailable: {reason}",
            new Dictionary<string, object?>
            {
                ["backend"] = backend,
                ["reason"] = reason,
            });

    /// <summary><see cref="DVAIBridgeErrorKind.BackendError"/> factory.</summary>
    public static DVAIBridgeException BackendError(string underlying, Exception? innerException = null) =>
        new(
            DVAIBridgeErrorKind.BackendError,
            $"DVAIBridge backend error: {underlying}",
            new Dictionary<string, object?>
            {
                ["underlying"] = underlying,
            },
            innerException);

    /// <summary><see cref="DVAIBridgeErrorKind.ChecksumMismatch"/> factory.</summary>
    public static DVAIBridgeException ChecksumMismatch(string expected, string got) =>
        new(
            DVAIBridgeErrorKind.ChecksumMismatch,
            $"DVAIBridge checksum mismatch: expected={expected}, got={got}",
            new Dictionary<string, object?>
            {
                ["expected"] = expected,
                ["got"] = got,
            });

    /// <summary><see cref="DVAIBridgeErrorKind.DownloadFailed"/> factory.</summary>
    public static DVAIBridgeException DownloadFailed(string reason, Exception? innerException = null) =>
        new(
            DVAIBridgeErrorKind.DownloadFailed,
            $"DVAIBridge download failed: {reason}",
            new Dictionary<string, object?>
            {
                ["reason"] = reason,
            },
            innerException);
}
