using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace DVAIBridge.Android.Discovery;

/// <summary>
/// Android peer discovery — delegates to the native Kotlin SDK's
/// <c>NsdDiscovery</c> when the AAR-bound wrapper is available;
/// otherwise runs as a logging stub that surfaces an empty peer list.
///
/// <para>
/// The native binding is being landed by Agent 8b in a parallel task.
/// As soon as the <c>BINDINGS_GENERATED</c> compile constant flips on
/// (CI's AAR-fetch step), swap the stub body for the real
/// <c>Native.NsdDiscovery</c> bridge — same shape as the iOS
/// <c>IOSDiscovery</c> stub in the iOS slice.
/// </para>
/// </summary>
internal sealed class AndroidDiscovery : IDiscovery
{
    private readonly string _ourDeviceId;
    private readonly object _listenerLock = new();
    private readonly List<Action<DiscoveryEvent>> _listeners = new();
    private readonly List<PeerInfo> _peers = new();
    private int _started;

    public AndroidDiscovery(string ourDeviceId)
    {
        _ourDeviceId = ourDeviceId ?? throw new ArgumentNullException(nameof(ourDeviceId));
    }

    public IReadOnlyList<PeerInfo> Peers
    {
        get { lock (_peers) return _peers.ToArray(); }
    }

    public Task StartAsync(CancellationToken ct = default)
    {
        if (Interlocked.CompareExchange(ref _started, 1, 0) != 0)
        {
            return Task.CompletedTask;
        }
        // TODO(8b): Bridge to NsdDiscovery once Agent 8b ships the Android
        // Kotlin binding. Emit "peer-up" / "peer-down" events and append to
        // _peers as the native side surfaces them.
        System.Diagnostics.Debug.WriteLine(
            "[DVAIBridge.Android] mDNS discovery is stubbed pending the native NsdDiscovery binding (Agent 8b).");
        return Task.CompletedTask;
    }

    public Task StopAsync(CancellationToken ct = default)
    {
        Volatile.Write(ref _started, 0);
        lock (_peers) _peers.Clear();
        return Task.CompletedTask;
    }

    public IDisposable Subscribe(Action<DiscoveryEvent> listener)
    {
        if (listener is null) throw new ArgumentNullException(nameof(listener));
        lock (_listenerLock) _listeners.Add(listener);
        return new Subscription(this, listener);
    }

    private sealed class Subscription : IDisposable
    {
        private readonly AndroidDiscovery _owner;
        private readonly Action<DiscoveryEvent> _listener;
        private bool _disposed;

        public Subscription(AndroidDiscovery owner, Action<DiscoveryEvent> listener)
        {
            _owner = owner;
            _listener = listener;
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            lock (_owner._listenerLock) _owner._listeners.Remove(_listener);
        }
    }
}

/// <summary>
/// Resolved by the facade's <c>PlatformBridgeFactory</c> via reflection
/// when the Android slice is loaded.
/// </summary>
internal sealed class AndroidDiscoveryFactory : IDiscoveryFactory
{
    public IDiscovery Create(string deviceId) => new AndroidDiscovery(deviceId);
}
