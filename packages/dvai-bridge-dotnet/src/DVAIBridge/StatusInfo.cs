namespace DVAIBridge;

/// <summary>
/// Snapshot of the bridge's current running state. Returned by
/// <see cref="DVAIBridge.GetStatusAsync(System.Threading.CancellationToken)"/>.
/// All fields except <see cref="Running"/> are nullable — when the bridge is
/// stopped they are null.
/// </summary>
/// <param name="Running">True when a backend is currently bound and serving HTTP requests.</param>
/// <param name="BaseUrl">The active server's base URL (e.g. <c>http://127.0.0.1:38883/v1</c>) or null.</param>
/// <param name="Port">The active server's port or null.</param>
/// <param name="Backend">The resolved <see cref="BackendKind"/> or null.</param>
/// <param name="ModelId">The active <c>ModelId</c> or null.</param>
public sealed record StatusInfo(
    bool Running,
    string? BaseUrl,
    int? Port,
    BackendKind? Backend,
    string? ModelId);
