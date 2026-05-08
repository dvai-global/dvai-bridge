using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Threading.Tasks;

[assembly: InternalsVisibleTo("DVAIBridge.iOS")]
[assembly: InternalsVisibleTo("DVAIBridge.Android")]
[assembly: InternalsVisibleTo("DVAIBridge.Desktop")]
[assembly: InternalsVisibleTo("DVAIBridge.OnnxRuntime")]
[assembly: InternalsVisibleTo("DVAIBridge.MLNet")]
[assembly: InternalsVisibleTo("DVAIBridge.Tests")]
[assembly: InternalsVisibleTo("DVAIBridge.Desktop.Tests")]
[assembly: InternalsVisibleTo("DVAIBridge.OnnxRuntime.Tests")]
[assembly: InternalsVisibleTo("DVAIBridge.MLNet.Tests")]

namespace DVAIBridge;

/// <summary>
/// The C# facade for the DVAIBridge family — single entry point for .NET
/// MAUI / Avalonia / WinUI / Xamarin (legacy) consumers wanting a local
/// LLM with an OpenAI-compatible HTTP server.
///
/// <para>
/// Use the singleton via <see cref="Shared"/>. For test isolation,
/// construct a fresh instance via the internal test-seam constructor.
/// </para>
///
/// <example>
/// <code>
/// using DVAIBridge;
///
/// var server = await DVAIBridge.Shared.StartAsync(new StartOptions
/// {
///     Backend = BackendKind.Auto,
///     ModelPath = "/path/to/model.gguf",
/// });
/// Console.WriteLine(server.BaseUrl); // http://127.0.0.1:38883/v1
///
/// await foreach (var ev in DVAIBridge.Shared.ProgressEvents.WithCancellation(ct))
///     Console.WriteLine($"{ev.Kind} {ev.Phase} {ev.Percent}");
///
/// await DVAIBridge.Shared.StopAsync();
/// </code>
/// </example>
/// </summary>
public sealed class DVAIBridge : IAsyncDisposable
{
    /// <summary>
    /// The set of <see cref="BackendKind"/> values that require an iOS or
    /// Mac Catalyst host (Apple-only frameworks). The facade pre-validates
    /// against the runtime platform; native bindings also enforce this for
    /// defense-in-depth.
    /// </summary>
    private static readonly HashSet<BackendKind> AppleOnly =
    [
        BackendKind.Foundation,
        BackendKind.CoreML,
        BackendKind.MLX,
    ];

    /// <summary>The set of <see cref="BackendKind"/> values that are Android-only.</summary>
    private static readonly HashSet<BackendKind> AndroidOnly =
    [
        BackendKind.MediaPipe,
        BackendKind.LiteRT,
    ];

    private static readonly Lazy<DVAIBridge> _shared =
        new(() => new DVAIBridge(new RoutingNativeBridge()));

    /// <summary>
    /// Singleton instance. Resolves the appropriate native bridge once at
    /// first access (iOS / Android / Unsupported per the runtime platform).
    /// </summary>
    public static DVAIBridge Shared => _shared.Value;

    private readonly INativeBridge _bridge;
    private readonly ProgressBroadcaster _progress = new();
    private readonly IDisposable _progressSubscription;
    private DVAIBridgeException? _lastError;
    private OffloadSession? _offload;
    private int _disposed; // 0 = live, 1 = disposed (CompareExchange-guarded)

    /// <summary>
    /// Stream of incoming pairing requests when offload is enabled
    /// (<see cref="StartOptions.Offload"/> with
    /// <see cref="OffloadConfig.Enabled"/> = <c>true</c>). Each request
    /// must be resolved by calling
    /// <see cref="PairingRequest.RespondAsync(bool, CancellationToken)"/>.
    /// Empty stream when offload is disabled.
    ///
    /// <example>
    /// <code>
    /// await foreach (var req in DVAIBridge.Shared.PairingRequests)
    /// {
    ///     var approved = await MyUiConfirm(req.PeerDeviceName);
    ///     await req.RespondAsync(approved);
    /// }
    /// </code>
    /// </example>
    /// </summary>
    public IAsyncEnumerable<PairingRequest> PairingRequests =>
        _offload?.PairingPolicy.Requests ?? EmptyAsync<PairingRequest>();

    /// <summary>
    /// Snapshot of currently known + discovered peers when offload is
    /// enabled. Empty list when offload is disabled.
    /// </summary>
    public IReadOnlyList<PeerInfo> Peers =>
        _offload?.Peers ?? Array.Empty<PeerInfo>();

    /// <summary>
    /// Stable per-install device ID surfaced when offload is enabled.
    /// <c>null</c> when offload is disabled.
    /// </summary>
    public string? DeviceId => _offload?.DeviceId;

    /// <summary>
    /// v3.2 — async pairing lookup used by the
    /// <c>DVAIBridge.Shared.Hosting.OffloadRouter</c> middleware in
    /// <c>DVAIBridge.Desktop</c> / <c>OnnxRuntime</c> / <c>MLNet</c>.
    /// Returns the active pairing for <paramref name="peerDeviceId"/>
    /// (TTL-aware per the configured pairing-expiry window),
    /// or <c>null</c> when offload is disabled / no pairing exists /
    /// the pairing has expired.
    /// </summary>
    public Task<global::DVAIBridge.Pairing.Pairing?> GetActivePairingAsync(string peerDeviceId, CancellationToken ct = default) =>
        _offload?.PairingPolicy.GetActiveAsync(peerDeviceId, ct) ??
        Task.FromResult<global::DVAIBridge.Pairing.Pairing?>(null);

    private static async IAsyncEnumerable<T> EmptyAsync<T>()
    {
        await Task.CompletedTask;
        yield break;
    }

    /// <summary>
    /// Internal test-seam constructor. Production code uses
    /// <see cref="Shared"/>. Tests construct a fresh instance with a fake
    /// <see cref="INativeBridge"/> for isolation from singleton state.
    /// </summary>
    internal DVAIBridge(INativeBridge bridge)
    {
        _bridge = bridge;
        _progressSubscription = bridge.SubscribeProgress(_progress.Emit);
    }

    /// <summary>
    /// v3.2 — pre-init hardware assessment.
    ///
    /// Returns a JSON-serializable description of how this device would
    /// handle local inference, BEFORE any model download/load. The SDK
    /// itself never shows UI for hardware decisions — consumer apps
    /// query this and decide their own UX based on the returned
    /// <see cref="Capability.PrecheckMode"/>:
    ///
    /// <list type="bullet">
    /// <item><see cref="Capability.PrecheckMode.Ok"/> → device can
    ///   comfortably run the model locally; <c>StartAsync</c> proceeds
    ///   normally.</item>
    /// <item><see cref="Capability.PrecheckMode.OffloadOnly"/> → device
    ///   can run but slowly (below
    ///   <see cref="OffloadConfig.MinLocalCapability"/>);
    ///   <c>StartAsync</c> skips the model load and routes every
    ///   request to a paired peer.</item>
    /// <item><see cref="Capability.PrecheckMode.TooWeak"/> → device is
    ///   below the hardware floor (3 tok/s by default);
    ///   <c>StartAsync</c> ALSO skips the model load. Consumers
    ///   typically bail rather than even calling <c>StartAsync</c>.</item>
    /// </list>
    ///
    /// The result is JSON-serializable
    /// (<see cref="System.Text.Json.JsonSerializer.Serialize{T}(T, System.Text.Json.JsonSerializerOptions?)"/>)
    /// so it round-trips cleanly through MAUI / Avalonia view-model
    /// bindings or Capacitor / RN bridges.
    /// </summary>
    public Capability.HardwareAssessment AssessHardware(
        double hardwareMinimum = Capability.CapabilityPrecheck.DefaultHardwareMinimum,
        double minLocalCapability = Capability.CapabilityPrecheck.DefaultMinLocalCapability) =>
        Capability.CapabilityPrecheck.Assess(
            hardwareMinimum: hardwareMinimum,
            minLocalCapability: minLocalCapability);

    /// <summary>
    /// Boot the embedded HTTP server with the given <see cref="StartOptions"/>.
    /// </summary>
    /// <param name="opts">Backend + model + sampling options.</param>
    /// <param name="ct">Cancels the start sequence; the bridge unbinds on cancel.</param>
    /// <returns>The bound, running <see cref="BoundServer"/>.</returns>
    /// <exception cref="DVAIBridgeException">
    /// On any failure: <see cref="DVAIBridgeErrorKind.AlreadyStarted"/> when
    /// a prior start is still bound; <see cref="DVAIBridgeErrorKind.BackendUnavailable"/>
    /// when the requested <see cref="BackendKind"/> isn't supported on the
    /// current platform; <see cref="DVAIBridgeErrorKind.ConfigurationInvalid"/>
    /// for bad <see cref="StartOptions"/>; <see cref="DVAIBridgeErrorKind.ModelLoadFailed"/>
    /// when the model file is rejected; <see cref="DVAIBridgeErrorKind.BackendError"/>
    /// for native steady-state failures.
    /// </exception>
    public async Task<BoundServer> StartAsync(StartOptions opts, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(opts);
        ValidatePlatform(opts.Backend);
        try
        {
            var server = await _bridge.StartAsync(opts, ct).ConfigureAwait(false);
            _lastError = null;
            if (opts.Offload is { Enabled: true } offloadConfig)
            {
                var factory = PlatformBridgeFactory.ResolveDiscoveryFactory();
                _offload = await OffloadSession.StartAsync(offloadConfig, factory, ct).ConfigureAwait(false);
            }
            return server;
        }
        catch (DVAIBridgeException ex)
        {
            _lastError = ex;
            throw;
        }
        catch (OperationCanceledException)
        {
            // Cancellation isn't a bridge error — let it propagate unwrapped.
            throw;
        }
        catch (Exception ex)
        {
            var wrapped = DVAIBridgeException.BackendError(ex.Message, ex);
            _lastError = wrapped;
            throw wrapped;
        }
    }

    /// <summary>Stop the embedded HTTP server. Idempotent.</summary>
    /// <param name="ct">Cancels the stop sequence (rarely used).</param>
    public async Task StopAsync(CancellationToken ct = default)
    {
        try
        {
            if (_offload is { } off)
            {
                _offload = null;
                await off.DisposeAsync().ConfigureAwait(false);
            }
            await _bridge.StopAsync(ct).ConfigureAwait(false);
        }
        catch (DVAIBridgeException ex)
        {
            _lastError = ex;
            throw;
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception ex)
        {
            var wrapped = DVAIBridgeException.BackendError(ex.Message, ex);
            _lastError = wrapped;
            throw wrapped;
        }
    }

    /// <summary>
    /// Snapshot the current bridge state. Polling-free alternative for
    /// "is the bridge currently running?" checks.
    /// </summary>
    /// <param name="ct">Cancels the snapshot fetch (rarely used).</param>
    public Task<StatusInfo> GetStatusAsync(CancellationToken ct = default) =>
        _bridge.GetStatusAsync(ct);

    /// <summary>
    /// Download a model file with sha256 verification. Wraps the per-platform
    /// resumable HTTP-Range downloader.
    /// </summary>
    /// <exception cref="DVAIBridgeException">
    /// <see cref="DVAIBridgeErrorKind.ChecksumMismatch"/> when the downloaded
    /// file's sha256 doesn't match <see cref="DownloadOptions.Sha256"/>;
    /// <see cref="DVAIBridgeErrorKind.DownloadFailed"/> for network or
    /// filesystem errors.
    /// </exception>
    public async Task<DownloadResult> DownloadModelAsync(DownloadOptions opts, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(opts);
        try
        {
            return await _bridge.DownloadModelAsync(opts, ct).ConfigureAwait(false);
        }
        catch (DVAIBridgeException ex)
        {
            _lastError = ex;
            throw;
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception ex)
        {
            var wrapped = DVAIBridgeException.BackendError(ex.Message, ex);
            _lastError = wrapped;
            throw wrapped;
        }
    }

    /// <summary>
    /// Push-style stream of <see cref="ProgressEvent"/>s. Each
    /// <c>await foreach</c> consumer gets every event (broadcast semantics);
    /// see <see cref="ProgressBroadcaster"/> for the implementation.
    /// </summary>
    /// <remarks>
    /// To convert to <c>IObservable&lt;ProgressEvent&gt;</c> for Rx-favoring
    /// consumers, call <c>.ToObservable()</c> from
    /// <c>System.Linq.Async</c> / <c>System.Reactive.Linq</c>.
    /// </remarks>
    public IAsyncEnumerable<ProgressEvent> ProgressEvents => _progress.Subscribe();

    /// <summary>
    /// Cancellable variant of <see cref="ProgressEvents"/>. Equivalent to
    /// <c>ProgressEvents.WithCancellation(ct)</c> but captured in a single
    /// method call site for ergonomic call-sites.
    /// </summary>
    /// <param name="ct">Cancels the consumer's enumeration without affecting other consumers.</param>
    public IAsyncEnumerable<ProgressEvent> GetProgressEventsAsync(CancellationToken ct = default) =>
        _progress.Subscribe(ct);

    /// <summary>
    /// Snapshot the current state, including the most recent unrecovered
    /// <see cref="DVAIBridgeException"/>. Useful for binding directly to a
    /// MAUI / Avalonia / WinUI view-model.
    /// </summary>
    public async ValueTask<DVAIBridgeState> GetStateAsync(CancellationToken ct = default)
    {
        var status = await _bridge.GetStatusAsync(ct).ConfigureAwait(false);
        return new DVAIBridgeState(
            IsReady: status.Running,
            BaseUrl: status.BaseUrl,
            Port: status.Port,
            Backend: status.Backend,
            ModelId: status.ModelId,
            LastError: _lastError);
    }

    /// <summary>
    /// Releases the progress subscription and completes any active
    /// <see cref="ProgressEvents"/> consumers. The underlying native bridge
    /// is left bound; call <see cref="StopAsync(CancellationToken)"/>
    /// first if you also want to release the native server.
    /// </summary>
    public async ValueTask DisposeAsync()
    {
        if (Interlocked.CompareExchange(ref _disposed, 1, 0) != 0)
        {
            return;
        }

        if (_offload is { } off)
        {
            _offload = null;
            await off.DisposeAsync().ConfigureAwait(false);
        }
        _progressSubscription.Dispose();
        _progress.Dispose();
    }

    /// <summary>
    /// Validate that <paramref name="backend"/> is supported on the current
    /// runtime platform per spec §3.8. Throws
    /// <see cref="DVAIBridgeException.BackendUnavailable"/> otherwise. The
    /// underlying <see cref="INativeBridge"/> implementations repeat this
    /// check for defense-in-depth.
    /// </summary>
    private static void ValidatePlatform(BackendKind backend)
    {
        // Onnx is cross-platform (any OS where the DVAIBridge.OnnxRuntime
        // NuGet's natives ship — every supported runtime in v2.4).
        if (backend == BackendKind.Onnx)
        {
            return;
        }

        // MLNet is desktop-primary (Windows / Linux / macOS / Catalyst).
        if (backend == BackendKind.MLNet)
        {
            if (IsAppleMobileOnly() || OperatingSystem.IsAndroid())
            {
                throw DVAIBridgeException.BackendUnavailable(
                    backend,
                    "BackendKind.MLNet is desktop-only (Windows / Linux / macOS / Catalyst). " +
                    "Use BackendKind.Onnx on iOS / Android instead.");
            }
            return;
        }

        // Apple-only backends (Foundation / CoreML / MLX) — iOS and Catalyst OK.
        if (AppleOnly.Contains(backend))
        {
            if (!OperatingSystem.IsIOS() && !OperatingSystem.IsMacCatalyst())
            {
                throw DVAIBridgeException.BackendUnavailable(
                    backend,
                    $"{backend} is iOS / Mac Catalyst only.");
            }
            return;
        }

        // Android-only backends (MediaPipe / LiteRT).
        if (AndroidOnly.Contains(backend))
        {
            if (!OperatingSystem.IsAndroid())
            {
                throw DVAIBridgeException.BackendUnavailable(
                    backend,
                    $"{backend} is Android-only.");
            }
            return;
        }

        // Auto / Llama: every platform with a slice. Auto resolves natively.
        // No further pre-validation here — LlamaDesktopBridge / IOSNativeBridge /
        // AndroidNativeBridge each enforce their own constraints.
    }

    private static bool IsAppleMobileOnly() =>
        OperatingSystem.IsIOS() && !OperatingSystem.IsMacCatalyst();
}

/// <summary>
/// Routing <see cref="INativeBridge"/> used by the singleton. Each
/// <see cref="StartAsync"/> call resolves the backend-specific bridge via
/// <see cref="PlatformBridgeFactory.Create(BackendKind)"/> and delegates
/// every subsequent call to the bound bridge instance. Stop / Status /
/// Download / SubscribeProgress operate against the most recently bound
/// bridge (the one started or — pre-start — the platform default).
/// </summary>
internal sealed class RoutingNativeBridge : INativeBridge, IDisposable
{
    private INativeBridge _current;
    private readonly object _lock = new();
    private readonly List<Action<ProgressEvent>> _handlers = [];
    private IDisposable? _innerSubscription;

    public RoutingNativeBridge()
    {
        // Pre-bind to the platform default so SubscribeProgress called BEFORE
        // a StartAsync still receives events from the eventual native side
        // (we re-attach all handlers to the new bridge inside Reroute()).
        _current = PlatformBridgeFactory.Create(BackendKind.Auto);
        _innerSubscription = _current.SubscribeProgress(FanOut);
    }

    public Task<BoundServer> StartAsync(StartOptions opts, CancellationToken ct)
    {
        Reroute(opts.Backend);
        return _current.StartAsync(opts, ct);
    }

    public Task StopAsync(CancellationToken ct) => _current.StopAsync(ct);
    public Task<StatusInfo> GetStatusAsync(CancellationToken ct) => _current.GetStatusAsync(ct);
    public Task<DownloadResult> DownloadModelAsync(DownloadOptions opts, CancellationToken ct) =>
        _current.DownloadModelAsync(opts, ct);

    public IDisposable SubscribeProgress(Action<ProgressEvent> handler)
    {
        lock (_lock) _handlers.Add(handler);
        return new Subscription(this, handler);
    }

    private void Reroute(BackendKind backend)
    {
        lock (_lock)
        {
            var next = PlatformBridgeFactory.Create(backend);
            if (ReferenceEquals(next, _current)) return;

            _innerSubscription?.Dispose();
            _current = next;
            _innerSubscription = _current.SubscribeProgress(FanOut);
        }
    }

    private void FanOut(ProgressEvent ev)
    {
        Action<ProgressEvent>[] snapshot;
        lock (_lock) snapshot = _handlers.ToArray();
        foreach (var h in snapshot) h(ev);
    }

    public void Dispose()
    {
        _innerSubscription?.Dispose();
        _innerSubscription = null;
    }

    private sealed class Subscription : IDisposable
    {
        private readonly RoutingNativeBridge _owner;
        private readonly Action<ProgressEvent> _handler;
        private bool _disposed;

        public Subscription(RoutingNativeBridge owner, Action<ProgressEvent> handler)
        {
            _owner = owner;
            _handler = handler;
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            lock (_owner._lock) _owner._handlers.Remove(_handler);
        }
    }
}
