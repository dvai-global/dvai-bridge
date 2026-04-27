using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Threading.Tasks;

[assembly: InternalsVisibleTo("DVAIBridge.iOS")]
[assembly: InternalsVisibleTo("DVAIBridge.Android")]
[assembly: InternalsVisibleTo("DVAIBridge.Tests")]

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
    /// The set of <see cref="BackendKind"/> values that are iOS-only. The
    /// facade pre-validates against the runtime platform; native bindings
    /// also enforce this for defense-in-depth.
    /// </summary>
    private static readonly HashSet<BackendKind> IosOnly =
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
        new(() => new DVAIBridge(PlatformBridgeFactory.Create()));

    /// <summary>
    /// Singleton instance. Resolves the appropriate native bridge once at
    /// first access (iOS / Android / Unsupported per the runtime platform).
    /// </summary>
    public static DVAIBridge Shared => _shared.Value;

    private readonly INativeBridge _bridge;
    private readonly ProgressBroadcaster _progress = new();
    private readonly IDisposable _progressSubscription;
    private DVAIBridgeException? _lastError;
    private int _disposed; // 0 = live, 1 = disposed (CompareExchange-guarded)

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
    public ValueTask DisposeAsync()
    {
        if (Interlocked.CompareExchange(ref _disposed, 1, 0) != 0)
        {
            return ValueTask.CompletedTask;
        }

        _progressSubscription.Dispose();
        _progress.Dispose();
        return ValueTask.CompletedTask;
    }

    /// <summary>
    /// Validate that <paramref name="backend"/> is supported on the current
    /// runtime platform. Throws <see cref="DVAIBridgeException.BackendUnavailable"/>
    /// otherwise. Native bindings repeat this check for defense-in-depth.
    /// </summary>
    private static void ValidatePlatform(BackendKind backend)
    {
        if (OperatingSystem.IsIOS())
        {
            if (AndroidOnly.Contains(backend))
            {
                throw DVAIBridgeException.BackendUnavailable(
                    backend,
                    $"{backend} is Android-only and is not supported on iOS.");
            }
            return;
        }

        if (OperatingSystem.IsAndroid())
        {
            if (IosOnly.Contains(backend))
            {
                throw DVAIBridgeException.BackendUnavailable(
                    backend,
                    $"{backend} is iOS-only and is not supported on Android.");
            }
            return;
        }

        // Anything that isn't iOS or Android: Windows, Linux, macOS, browser, etc.
        throw DVAIBridgeException.BackendUnavailable(
            backend,
            "DVAIBridge native bindings only ship for iOS and Android in v2.4. " +
            "WinUI 3 / Avalonia / desktop / Blazor consumers can compile against " +
            "the facade but every API call fails with this exception.");
    }
}
