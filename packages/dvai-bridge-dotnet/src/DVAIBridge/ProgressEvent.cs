namespace DVAIBridge;

/// <summary>
/// Discriminator for a <see cref="ProgressEvent"/> — distinguishes lifecycle
/// kinds (started / progress / completed / failed) from one another.
/// </summary>
public enum ProgressKind
{
    /// <summary>Phase began.</summary>
    Started,

    /// <summary>Phase produced an incremental update (e.g. percent, bytes received).</summary>
    Progress,

    /// <summary>Phase finished successfully.</summary>
    Completed,

    /// <summary>Phase finished with an error — see <see cref="ProgressEvent.ErrorKind"/> + <see cref="ProgressEvent.ErrorMessage"/>.</summary>
    Failed,
}

/// <summary>
/// The lifecycle phase a <see cref="ProgressEvent"/> belongs to. Mirrors the
/// iOS <c>ProgressEvent.Phase</c> Swift enum and the Android equivalent.
/// </summary>
public enum ProgressPhase
{
    /// <summary>Server start sequence.</summary>
    Start,

    /// <summary>Server stop sequence.</summary>
    Stop,

    /// <summary>Model download.</summary>
    Download,

    /// <summary>Model load into the backend.</summary>
    Load,

    /// <summary>Backend ready / serving requests.</summary>
    Ready,

    /// <summary>Checksum verification step (post-download).</summary>
    Verify,

    /// <summary>Error path — paired with <see cref="ProgressKind.Failed"/>.</summary>
    Error,
}

/// <summary>
/// Reactive-progress event emitted by the bridge during long-running
/// operations (start, stop, download). Consume via
/// <see cref="DVAIBridge.ProgressEvents"/>'s
/// <see cref="System.Collections.Generic.IAsyncEnumerable{T}"/> surface.
/// </summary>
/// <param name="Kind">Lifecycle discriminator.</param>
/// <param name="Phase">Which lifecycle phase the event belongs to.</param>
/// <param name="Percent">
/// Optional 0-100 percentage. Null for events that aren't natively
/// progress-shaped (e.g. <see cref="ProgressKind.Started"/>).
/// </param>
/// <param name="Message">Optional human-readable status string.</param>
/// <param name="ErrorKind">
/// Optional error-kind discriminator. Populated only when
/// <see cref="Kind"/> is <see cref="ProgressKind.Failed"/>; the value matches
/// <see cref="DVAIBridgeException.Kind"/>'s lowercase wire string.
/// </param>
/// <param name="ErrorMessage">Optional error message. Populated only when <see cref="Kind"/> is <see cref="ProgressKind.Failed"/>.</param>
public sealed record ProgressEvent(
    ProgressKind Kind,
    ProgressPhase Phase,
    double? Percent = null,
    string? Message = null,
    string? ErrorKind = null,
    string? ErrorMessage = null);
