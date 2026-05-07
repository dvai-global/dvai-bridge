using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace DVAIBridge.iOS.Discovery;

/// <summary>
/// iOS / Mac Catalyst peer discovery — delegates to the native Swift
/// SDK's <c>NWBrowserDiscovery</c> when the binding's
/// <c>Native.NWBrowserDiscovery</c> wrapper is available; otherwise
/// runs as a logging stub that surfaces an empty peer list.
///
/// <para>
/// The native binding is being landed by Agent 8a in a parallel task.
/// As soon as <c>DVAIBridge.iOS</c>'s <c>ApiDefinition.cs</c> exposes
/// the <c>NWBrowserDiscovery</c> binding, swap the stub body below
/// for the real bridging code (start the browser, surface
/// <c>peer-up</c> / <c>peer-down</c> via the listeners list).
/// </para>
/// </summary>
internal sealed class IOSDiscovery : IDiscovery
{
    private readonly string _ourDeviceId;
    private readonly object _listenerLock = new();
    private readonly List<Action<DiscoveryEvent>> _listeners = new();
    private readonly List<PeerInfo> _peers = new();
    private int _started;

    public IOSDiscovery(string ourDeviceId)
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
        // TODO(8a): Bridge to the native NWBrowserDiscovery once Agent 8a
        // ships the iOS Swift binding. Emit "peer-up" / "peer-down" events
        // and append to _peers as the native side surfaces them.
        System.Diagnostics.Debug.WriteLine(
            "[DVAIBridge.iOS] mDNS discovery is stubbed pending the native NWBrowserDiscovery binding (Agent 8a).");
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
        private readonly IOSDiscovery _owner;
        private readonly Action<DiscoveryEvent> _listener;
        private bool _disposed;

        public Subscription(IOSDiscovery owner, Action<DiscoveryEvent> listener)
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
/// when the iOS slice is loaded.
/// </summary>
internal sealed class IOSDiscoveryFactory : IDiscoveryFactory
{
    public IDiscovery Create(string deviceId) => new IOSDiscovery(deviceId);
}
