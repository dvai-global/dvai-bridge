using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using DVAIBridge.Shared.Hosting;

namespace DVAIBridge.Desktop;

/// <summary>
/// Desktop-side <see cref="INativeBridge"/> implementation. Wires
/// <see cref="LlamaInferenceEngine"/> (P/Invoke into <c>llama.cpp</c>) into
/// <see cref="OpenAIServer"/> (Kestrel-hosted /v1/* surface). Resolved at
/// runtime by <c>PlatformBridgeFactory</c> via
/// <c>Type.GetType("DVAIBridge.Desktop.LlamaDesktopBridge, DVAIBridge.Desktop")</c>.
/// </summary>
internal sealed class LlamaDesktopBridge : INativeBridge
{
    private readonly object _lock = new();
    private readonly List<Action<ProgressEvent>> _handlers = [];
    private OpenAIServer? _server;
    private BackendKind _activeBackend = BackendKind.Llama;
    private string? _modelId;

    public LlamaDesktopBridge() { }

    public async Task<BoundServer> StartAsync(StartOptions opts, CancellationToken ct)
    {
        if (_server is not null)
        {
            throw DVAIBridgeException.AlreadyStarted(_activeBackend, _server.BaseUrl);
        }

        if (opts.Backend != BackendKind.Auto && opts.Backend != BackendKind.Llama)
        {
            throw DVAIBridgeException.BackendUnavailable(
                opts.Backend,
                $"Desktop slice supports only BackendKind.Llama (got {opts.Backend}). " +
                "For other backends install DVAIBridge.OnnxRuntime (BackendKind.Onnx) or DVAIBridge.MLNet (BackendKind.MLNet).");
        }

        if (string.IsNullOrEmpty(opts.ModelPath))
        {
            throw DVAIBridgeException.ConfigurationInvalid("ModelPath is required for the Llama desktop backend.");
        }

        EmitProgress(new ProgressEvent(ProgressKind.Started, ProgressPhase.Start));

        var engine = await LlamaInferenceEngine.CreateAsync(opts.ModelPath, opts, EmitProgress, ct).ConfigureAwait(false);
        _modelId = engine.ModelId;

        var server = new OpenAIServer(engine, BackendKind.Llama, opts.CorsOrigin);
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
        _activeBackend = BackendKind.Llama;
        EmitProgress(new ProgressEvent(ProgressKind.Completed, ProgressPhase.Ready, 100.0));
        return new BoundServer(server.BaseUrl, server.Port, BackendKind.Llama, _modelId!);
    }

    public async Task StopAsync(CancellationToken ct)
    {
        if (_server is null) return;
        var s = _server;
        _server = null;
        EmitProgress(new ProgressEvent(ProgressKind.Started, ProgressPhase.Stop));
        await s.DisposeAsync().ConfigureAwait(false);
        EmitProgress(new ProgressEvent(ProgressKind.Completed, ProgressPhase.Stop));
    }

    public Task<StatusInfo> GetStatusAsync(CancellationToken ct) =>
        Task.FromResult(_server is null
            ? new StatusInfo(false, null, null, null, null)
            : new StatusInfo(true, _server.BaseUrl, _server.Port, _activeBackend, _modelId));

    public async Task<DownloadResult> DownloadModelAsync(DownloadOptions opts, CancellationToken ct)
    {
        EmitProgress(new ProgressEvent(ProgressKind.Started, ProgressPhase.Download, 0.0));
        var dest = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "dvai-bridge",
            "models",
            opts.DestFilename ?? Path.GetFileName(new Uri(opts.Url).LocalPath));
        Directory.CreateDirectory(Path.GetDirectoryName(dest)!);

        using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(30) };
        try
        {
            using var rsp = await http.GetAsync(opts.Url, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);
            rsp.EnsureSuccessStatusCode();
            var total = rsp.Content.Headers.ContentLength ?? -1L;
            await using (var src = await rsp.Content.ReadAsStreamAsync(ct).ConfigureAwait(false))
            await using (var dst = File.Create(dest))
            {
                var buf = new byte[81920];
                long copied = 0;
                int read;
                while ((read = await src.ReadAsync(buf.AsMemory(0, buf.Length), ct).ConfigureAwait(false)) > 0)
                {
                    await dst.WriteAsync(buf.AsMemory(0, read), ct).ConfigureAwait(false);
                    copied += read;
                    if (total > 0)
                    {
                        EmitProgress(new ProgressEvent(ProgressKind.Progress, ProgressPhase.Download,
                            (double)copied / total * 100.0));
                    }
                }
            }
        }
        catch (Exception ex) when (ex is not DVAIBridgeException and not OperationCanceledException)
        {
            throw DVAIBridgeException.DownloadFailed(ex.Message);
        }

        // Verify SHA256.
        EmitProgress(new ProgressEvent(ProgressKind.Started, ProgressPhase.Verify));
        var hash = await Task.Run(() =>
        {
            using var sha = SHA256.Create();
            using var fs = File.OpenRead(dest);
            return Convert.ToHexString(sha.ComputeHash(fs)).ToLowerInvariant();
        }, ct).ConfigureAwait(false);

        if (!string.Equals(hash, opts.Sha256.ToLowerInvariant(), StringComparison.Ordinal))
        {
            try { File.Delete(dest); } catch { /* best-effort cleanup */ }
            throw DVAIBridgeException.ChecksumMismatch(opts.Sha256, hash);
        }

        var size = new FileInfo(dest).Length;
        EmitProgress(new ProgressEvent(ProgressKind.Completed, ProgressPhase.Verify, 100.0));
        return new DownloadResult(dest, hash, size);
    }

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
        private readonly LlamaDesktopBridge _owner;
        private readonly Action<ProgressEvent> _handler;
        private bool _disposed;

        public Subscription(LlamaDesktopBridge owner, Action<ProgressEvent> handler)
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
