using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace DVAIBridge.Tests.Fakes;

/// <summary>
/// Configurable in-memory <see cref="INativeBridge"/> fake. Used by every
/// xUnit test in this assembly to drive the facade without instantiating
/// any real native bridge.
/// </summary>
internal sealed class FakeNativeBridge : INativeBridge
{
    public Func<StartOptions, CancellationToken, Task<BoundServer>>? StartHandler { get; set; }
    public Func<CancellationToken, Task>? StopHandler { get; set; }
    public Func<CancellationToken, Task<StatusInfo>>? StatusHandler { get; set; }
    public Func<DownloadOptions, CancellationToken, Task<DownloadResult>>? DownloadHandler { get; set; }

    public List<Action<ProgressEvent>> ProgressHandlers { get; } = [];
    public int StopCallCount { get; private set; }
    public int StartCallCount { get; private set; }
    public int StatusCallCount { get; private set; }
    public int DownloadCallCount { get; private set; }

    public Task<BoundServer> StartAsync(StartOptions opts, CancellationToken ct)
    {
        StartCallCount++;
        return StartHandler is { } h
            ? h(opts, ct)
            : Task.FromResult(new BoundServer("http://127.0.0.1:38883/v1", 38883, opts.Backend, opts.ModelId ?? "fake-model"));
    }

    public Task StopAsync(CancellationToken ct)
    {
        StopCallCount++;
        return StopHandler is { } h ? h(ct) : Task.CompletedTask;
    }

    public Task<StatusInfo> GetStatusAsync(CancellationToken ct)
    {
        StatusCallCount++;
        return StatusHandler is { } h
            ? h(ct)
            : Task.FromResult(new StatusInfo(false, null, null, null, null));
    }

    public Task<DownloadResult> DownloadModelAsync(DownloadOptions opts, CancellationToken ct)
    {
        DownloadCallCount++;
        return DownloadHandler is { } h
            ? h(opts, ct)
            : Task.FromResult(new DownloadResult("/tmp/fake.gguf", opts.Sha256, 1024L));
    }

    public IDisposable SubscribeProgress(Action<ProgressEvent> handler)
    {
        ProgressHandlers.Add(handler);
        return new Subscription(this, handler);
    }

    /// <summary>
    /// Push a fake progress event through every registered handler. Tests
    /// use this to simulate native-side emissions.
    /// </summary>
    public void EmitProgress(ProgressEvent ev)
    {
        // Snapshot the list so handlers that unsubscribe during iteration
        // don't ConcurrentModificationException.
        foreach (var h in ProgressHandlers.ToArray())
        {
            h(ev);
        }
    }

    private sealed class Subscription : IDisposable
    {
        private readonly FakeNativeBridge _owner;
        private readonly Action<ProgressEvent> _handler;
        private bool _disposed;

        public Subscription(FakeNativeBridge owner, Action<ProgressEvent> handler)
        {
            _owner = owner;
            _handler = handler;
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            _owner.ProgressHandlers.Remove(_handler);
        }
    }
}
