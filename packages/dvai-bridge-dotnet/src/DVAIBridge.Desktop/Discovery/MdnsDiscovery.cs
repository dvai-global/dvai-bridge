using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Makaretu.Dns;

namespace DVAIBridge.Desktop.Discovery;

/// <summary>
/// LAN peer discovery via mDNS / DNS-SD. Browses for
/// <c>_dvai-bridge._tcp.local</c> service instances on the local
/// network and surfaces them as <see cref="PeerInfo"/> records via
/// the <see cref="IDiscovery"/> contract.
///
/// <para>
/// Filters out any instance whose <c>device_id</c> TXT entry matches
/// our own — we never want to "discover" ourselves.
/// </para>
/// </summary>
public sealed class MdnsDiscovery : IDiscovery, IAsyncDisposable
{
    private readonly string _ourDeviceId;
    private readonly ConcurrentDictionary<string, PeerInfo> _peers = new();
    private readonly object _listenerLock = new();
    private readonly List<Action<DiscoveryEvent>> _listeners = new();
    private MulticastService? _mdns;
    private ServiceDiscovery? _sd;
    private int _started;
    private int _disposed;

    /// <summary>Construct an mDNS discovery client for this device.</summary>
    public MdnsDiscovery(string ourDeviceId)
    {
        _ourDeviceId = ourDeviceId ?? throw new ArgumentNullException(nameof(ourDeviceId));
    }

    /// <inheritdoc />
    public IReadOnlyList<PeerInfo> Peers => _peers.Values.ToList();

    /// <inheritdoc />
    public Task StartAsync(CancellationToken ct = default)
    {
        if (Interlocked.CompareExchange(ref _started, 1, 0) != 0)
        {
            return Task.CompletedTask;
        }

        try
        {
            _mdns = new MulticastService();
            _sd = new ServiceDiscovery(_mdns);
            _sd.ServiceInstanceDiscovered += OnInstanceDiscovered;
            _sd.ServiceInstanceShutdown += OnInstanceShutdown;
            _mdns.AnswerReceived += OnAnswerReceived;
            _mdns.Start();
            _sd.QueryServiceInstances($"{MdnsAdvertiser.ServiceType}.local");
        }
        catch
        {
            Volatile.Write(ref _started, 0);
            throw;
        }
        return Task.CompletedTask;
    }

    /// <inheritdoc />
    public Task StopAsync(CancellationToken ct = default)
    {
        if (Volatile.Read(ref _started) == 0)
        {
            return Task.CompletedTask;
        }
        if (_sd is not null)
        {
            _sd.ServiceInstanceDiscovered -= OnInstanceDiscovered;
            _sd.ServiceInstanceShutdown -= OnInstanceShutdown;
        }
        if (_mdns is not null)
        {
            _mdns.AnswerReceived -= OnAnswerReceived;
        }
        try { _sd?.Dispose(); } catch { /* best-effort */ }
        try { _mdns?.Stop(); } catch { /* best-effort */ }
        try { _mdns?.Dispose(); } catch { /* best-effort */ }
        _sd = null;
        _mdns = null;
        _peers.Clear();
        Volatile.Write(ref _started, 0);
        return Task.CompletedTask;
    }

    /// <inheritdoc />
    public IDisposable Subscribe(Action<DiscoveryEvent> listener)
    {
        if (listener is null) throw new ArgumentNullException(nameof(listener));
        lock (_listenerLock) _listeners.Add(listener);
        return new Subscription(this, listener);
    }

    /// <inheritdoc />
    public async ValueTask DisposeAsync()
    {
        if (Interlocked.CompareExchange(ref _disposed, 1, 0) != 0) return;
        await StopAsync().ConfigureAwait(false);
    }

    private void OnInstanceDiscovered(object? sender, ServiceInstanceDiscoveryEventArgs e)
    {
        // Ask for the SRV/TXT/A records for this specific instance.
        try { _sd?.QueryServiceInstances(e.ServiceInstanceName); } catch { /* race on shutdown */ }
        TryUpsertFromMessage(e.Message, e.RemoteEndPoint);
    }

    private void OnInstanceShutdown(object? sender, ServiceInstanceShutdownEventArgs e)
    {
        if (TryGetDeviceIdFromInstance(e.ServiceInstanceName.ToString(), out var deviceId))
        {
            if (_peers.TryRemove(deviceId, out _))
            {
                Emit(new DiscoveryEvent("peer-down", DeviceId: deviceId));
            }
        }
    }

    private void OnAnswerReceived(object? sender, MessageEventArgs e)
    {
        TryUpsertFromMessage(e.Message, e.RemoteEndPoint);
    }

    private void TryUpsertFromMessage(Message msg, IPEndPoint? remote)
    {
        try
        {
            // Look for SRV + TXT + A/AAAA records for an _dvai-bridge instance.
            var allRecords = msg.Answers.Concat(msg.AdditionalRecords).ToList();
            var srv = allRecords.OfType<SRVRecord>().FirstOrDefault(r =>
                r.Name.ToString().IndexOf(MdnsAdvertiser.ServiceType, StringComparison.OrdinalIgnoreCase) >= 0);
            if (srv is null) return;

            var txt = allRecords.OfType<TXTRecord>().FirstOrDefault(r =>
                r.Name.ToString().Equals(srv.Name.ToString(), StringComparison.OrdinalIgnoreCase));

            var props = ParseTxt(txt);
            if (!props.TryGetValue("device_id", out var deviceId) || string.IsNullOrEmpty(deviceId))
            {
                return;
            }
            if (string.Equals(deviceId, _ourDeviceId, StringComparison.Ordinal))
            {
                // Ignore our own advertisement.
                return;
            }

            var address = ResolveAddress(srv, allRecords, remote);
            if (string.IsNullOrEmpty(address)) return;

            var port = srv.Port;
            var secure = props.TryGetValue("secure", out var sec) &&
                         string.Equals(sec, "true", StringComparison.OrdinalIgnoreCase);
            var scheme = secure ? "https" : "http";
            var baseUrl = $"{scheme}://{address}:{port}/v1";

            props.TryGetValue("device_name", out var deviceName);
            props.TryGetValue("dvai_version", out var dvaiVersion);
            props.TryGetValue("loaded_models", out var loadedModelsCsv);
            var loadedModels = string.IsNullOrEmpty(loadedModelsCsv)
                ? Array.Empty<string>()
                : loadedModelsCsv!.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);

            var peer = new PeerInfo
            {
                DeviceId = deviceId,
                DeviceName = string.IsNullOrEmpty(deviceName) ? deviceId : deviceName!,
                DvaiVersion = string.IsNullOrEmpty(dvaiVersion) ? "0.0.0" : dvaiVersion!,
                BaseUrl = baseUrl,
                LoadedModels = loadedModels,
                Capability = new Dictionary<string, double>(),
                Via = "mdns",
                Secure = secure,
                LastSeenAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
            };

            var isNew = !_peers.ContainsKey(deviceId);
            _peers[deviceId] = peer;
            if (isNew) Emit(new DiscoveryEvent("peer-up", Peer: peer));
        }
        catch (Exception ex)
        {
            Emit(new DiscoveryEvent("error", Message: ex.Message));
        }
    }

    private static Dictionary<string, string> ParseTxt(TXTRecord? txt)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (txt is null) return result;
        foreach (var entry in txt.Strings)
        {
            var idx = entry.IndexOf('=');
            if (idx < 0) continue;
            var k = entry.Substring(0, idx);
            var v = entry.Substring(idx + 1);
            result[k] = v;
        }
        return result;
    }

    private static string ResolveAddress(SRVRecord srv, IList<ResourceRecord> all, IPEndPoint? remote)
    {
        // Prefer A / AAAA records keyed to the SRV target hostname.
        var target = srv.Target.ToString();
        var a = all.OfType<ARecord>().FirstOrDefault(r =>
            r.Name.ToString().Equals(target, StringComparison.OrdinalIgnoreCase));
        if (a is not null) return a.Address.ToString();
        var aaaa = all.OfType<AAAARecord>().FirstOrDefault(r =>
            r.Name.ToString().Equals(target, StringComparison.OrdinalIgnoreCase));
        if (aaaa is not null) return $"[{aaaa.Address}]";

        // Fall back to remote-endpoint IP if the records didn't include an address.
        if (remote is not null)
        {
            return remote.Address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetworkV6
                ? $"[{remote.Address}]"
                : remote.Address.ToString();
        }
        return string.Empty;
    }

    private static bool TryGetDeviceIdFromInstance(string instanceName, out string deviceId)
    {
        // Instance names look like "dvai-{deviceId}._dvai-bridge._tcp.local"
        deviceId = string.Empty;
        if (string.IsNullOrEmpty(instanceName)) return false;
        var first = instanceName.Split('.')[0];
        if (first.StartsWith("dvai-", StringComparison.OrdinalIgnoreCase))
        {
            deviceId = first.Substring("dvai-".Length);
            return !string.IsNullOrEmpty(deviceId);
        }
        return false;
    }

    private void Emit(DiscoveryEvent ev)
    {
        Action<DiscoveryEvent>[] snapshot;
        lock (_listenerLock) snapshot = _listeners.ToArray();
        foreach (var l in snapshot)
        {
            try { l(ev); } catch { /* listener errors must not break discovery */ }
        }
    }

    private sealed class Subscription : IDisposable
    {
        private readonly MdnsDiscovery _owner;
        private readonly Action<DiscoveryEvent> _listener;
        private bool _disposed;

        public Subscription(MdnsDiscovery owner, Action<DiscoveryEvent> listener)
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
/// Resolved by the facade's PlatformBridgeFactory via reflection when
/// the desktop NuGet is loaded — supplies fresh
/// <see cref="MdnsDiscovery"/> instances per <c>OffloadConfig</c>
/// activation.
/// </summary>
public sealed class MdnsDiscoveryFactory : IDiscoveryFactory
{
    /// <inheritdoc />
    public IDiscovery Create(string deviceId) => new MdnsDiscovery(deviceId);
}
