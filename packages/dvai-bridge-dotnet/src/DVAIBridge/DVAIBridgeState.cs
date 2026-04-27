namespace DVAIBridge;

/// <summary>
/// Snapshot of the bridge's reactive state. Returned by
/// <see cref="DVAIBridge.GetStateAsync(System.Threading.CancellationToken)"/>.
/// Distinct from <see cref="StatusInfo"/> in that it can also surface the
/// most recent error (useful for "is the bridge in a healthy state right now?"
/// checks in MAUI / Avalonia view models).
/// </summary>
/// <param name="IsReady">True when a backend is bound and serving requests.</param>
/// <param name="BaseUrl">Active server's base URL or null.</param>
/// <param name="Port">Active server's port or null.</param>
/// <param name="Backend">Resolved <see cref="BackendKind"/> or null.</param>
/// <param name="ModelId">Active <c>ModelId</c> or null.</param>
/// <param name="LastError">
/// Most recent non-recovered error, if any. Cleared on the next successful
/// <see cref="DVAIBridge.StartAsync(StartOptions, System.Threading.CancellationToken)"/>.
/// </param>
public sealed record DVAIBridgeState(
    bool IsReady,
    string? BaseUrl,
    int? Port,
    BackendKind? Backend,
    string? ModelId,
    DVAIBridgeException? LastError);
