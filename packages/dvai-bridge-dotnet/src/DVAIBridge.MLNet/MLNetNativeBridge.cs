using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using DVAIBridge.Shared.Hosting;

namespace DVAIBridge.MLNet;

/// <summary>
/// Desktop-primary <see cref="INativeBridge"/> backed by ML.NET +
/// <c>OnnxScoringEstimator</c>. Resolved at runtime by
/// <c>PlatformBridgeFactory</c> when a consumer requests
/// <see cref="BackendKind.MLNet"/> AND has installed the
/// <c>DVAIBridge.MLNet</c> NuGet AND the host is desktop (non-mobile).
/// </summary>
internal sealed class MLNetNativeBridge : INativeBridge
{
    private readonly object _lock = new();
    private readonly List<Action<ProgressEvent>> _handlers = [];
    private OpenAIServer? _server;
    private string? _modelId;

    public MLNetNativeBridge() { }

    public async Task<BoundServer> StartAsync(StartOptions opts, CancellationToken ct)
    {
        if (_server is not null)
        {
            throw DVAIBridgeException.AlreadyStarted(BackendKind.MLNet, _server.BaseUrl);
        }

        if (opts.Backend != BackendKind.MLNet && opts.Backend != BackendKind.Auto)
        {
            throw DVAIBridgeException.BackendUnavailable(
                opts.Backend,
                $"MLNetNativeBridge only handles BackendKind.MLNet (got {opts.Backend}).");
        }

        if (string.IsNullOrEmpty(opts.ModelPath))
        {
            throw DVAIBridgeException.ConfigurationInvalid("ModelPath is required for the ML.NET backend (path to a .onnx model).");
        }

        EmitProgress(new ProgressEvent(ProgressKind.Started, ProgressPhase.Start));
        EmitProgress(new ProgressEvent(ProgressKind.Started, ProgressPhase.Load, 0.0));

        var modelId = opts.ModelId ?? Path.GetFileNameWithoutExtension(opts.ModelPath);
        MLNetInferenceEngine engine;
        try
        {
            engine = await MLNetInferenceEngine.CreateAsync(opts.ModelPath, opts.TokenizerPath, modelId, ct).ConfigureAwait(false);
        }
        catch (DVAIBridgeException) { throw; }
        catch (Exception ex)
        {
            throw DVAIBridgeException.ModelLoadFailed(ex.Message);
        }

        _modelId = modelId;

        // v3.2 — install the pre-routing OffloadRouter when
        // OffloadConfig.Enabled is true. See LlamaDesktopBridge for
        // the full lifecycle note.
        var server = new OpenAIServer(engine, BackendKind.MLNet, opts.CorsOrigin,
            offloadRouter: OffloadRouterFactory.BuildOffloadRouterIfEnabled(opts));
        try
        {
            await server.StartAsync(opts.HttpBasePort, opts.HttpMaxPortAttempts, ct).ConfigureAwait(false);
        }
        catch
        {
            await server.DisposeAsync().ConfigureAwait(false);
            throw;
        }

        _server = server;
        EmitProgress(new ProgressEvent(ProgressKind.Completed, ProgressPhase.Ready, 100.0));
        return new BoundServer(server.BaseUrl, server.Port, BackendKind.MLNet, modelId);
    }

    public async Task StopAsync(CancellationToken ct)
    {
        if (_server is null) return;
        var s = _server;
        _server = null;
        await s.DisposeAsync().ConfigureAwait(false);
        EmitProgress(new ProgressEvent(ProgressKind.Completed, ProgressPhase.Stop));
    }

    public Task<StatusInfo> GetStatusAsync(CancellationToken ct) =>
        Task.FromResult(_server is null
            ? new StatusInfo(false, null, null, null, null)
            : new StatusInfo(true, _server.BaseUrl, _server.Port, BackendKind.MLNet, _modelId));

    public Task<DownloadResult> DownloadModelAsync(DownloadOptions opts, CancellationToken ct) =>
        Task.FromException<DownloadResult>(DVAIBridgeException.ConfigurationInvalid(
            "ML.NET backend doesn't ship a built-in downloader. Use the desktop slice's " +
            "DownloadModelAsync, the HuggingFace CLI, or `Microsoft.ML.OnnxRuntime`'s tooling."));

    public IDisposable SubscribeProgress(Action<ProgressEvent> handler)
    {
        lock (_lock) _handlers.Add(handler);
        return new Subscription(this, handler);
    }

    private void EmitProgress(ProgressEvent ev)
    {
        Action<ProgressEvent>[] snapshot;
        lock (_lock) snapshot = _handlers.ToArray();
        foreach (var h in snapshot) h(ev);
    }

    private sealed class Subscription : IDisposable
    {
        private readonly MLNetNativeBridge _owner;
        private readonly Action<ProgressEvent> _handler;
        private bool _disposed;

        public Subscription(MLNetNativeBridge owner, Action<ProgressEvent> handler)
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
