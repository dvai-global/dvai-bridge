using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;
using Makaretu.Dns;

namespace DVAIBridge.Desktop.Discovery;

/// <summary>
/// Advertises this host on mDNS as a <c>_dvai-bridge._tcp.local</c>
/// service so peer devices can discover us via <see cref="MdnsDiscovery"/>.
/// TXT records carry the device ID, library version, base URL, and the
/// list of currently-loaded models.
///
/// <para>
/// Per RFC 6762 (Multicast DNS) the advertiser owns a long-lived
/// <see cref="MulticastService"/> + <see cref="ServiceDiscovery"/> pair.
/// Calling <see cref="StartAsync"/> registers the service profile;
/// <see cref="StopAsync"/> unregisters it (sending a goodbye packet so
/// peers drop the entry promptly).
/// </para>
/// </summary>
public sealed class MdnsAdvertiser : IAsyncDisposable
{
    /// <summary>The mDNS service type — must match the consumer side exactly.</summary>
    public const string ServiceType = "_dvai-bridge._tcp";

    private readonly string _deviceId;
    private readonly string _deviceName;
    private readonly string _dvaiVersion;
    private readonly int _port;
    private readonly bool _secure;
    private readonly Func<IReadOnlyList<string>> _loadedModelsProvider;
    private MulticastService? _mdns;
    private ServiceDiscovery? _sd;
    private ServiceProfile? _profile;
    private int _started;
    private int _disposed;

    /// <summary>
    /// Construct an advertiser for the given device identity. The
    /// <paramref name="loadedModelsProvider"/> is invoked at start time
    /// to populate the TXT record; re-advertise (stop + start) to update.
    /// </summary>
    public MdnsAdvertiser(
        string deviceId,
        string deviceName,
        string dvaiVersion,
        int port,
        bool secure,
        Func<IReadOnlyList<string>>? loadedModelsProvider = null)
    {
        _deviceId = deviceId ?? throw new ArgumentNullException(nameof(deviceId));
        _deviceName = string.IsNullOrWhiteSpace(deviceName) ? Environment.MachineName : deviceName;
        _dvaiVersion = dvaiVersion ?? "0.0.0";
        _port = port;
        _secure = secure;
        _loadedModelsProvider = loadedModelsProvider ?? (() => Array.Empty<string>());
    }

    /// <summary>The mDNS instance name (defaults to <c>{deviceId}.{ServiceType}.local</c>).</summary>
    public string InstanceName => $"dvai-{_deviceId}";

    /// <summary>Begin advertising. Idempotent — a second call is a no-op.</summary>
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

            var addresses = LocalAddresses().ToList();
            _profile = new ServiceProfile(InstanceName, $"{ServiceType}.local", (ushort)_port, addresses);
            _profile.AddProperty("device_id", _deviceId);
            _profile.AddProperty("device_name", _deviceName);
            _profile.AddProperty("dvai_version", _dvaiVersion);
            _profile.AddProperty("secure", _secure ? "true" : "false");
            var loaded = _loadedModelsProvider();
            if (loaded.Count > 0)
            {
                _profile.AddProperty("loaded_models", string.Join(",", loaded));
            }

            _sd.Advertise(_profile);
            _mdns.Start();
        }
        catch
        {
            // Roll back the started flag if init blew up — caller can retry.
            Volatile.Write(ref _started, 0);
            throw;
        }
        return Task.CompletedTask;
    }

    /// <summary>Stop advertising. Idempotent.</summary>
    public Task StopAsync(CancellationToken ct = default)
    {
        if (Volatile.Read(ref _started) == 0)
        {
            return Task.CompletedTask;
        }
        try { if (_profile is not null && _sd is not null) _sd.Unadvertise(_profile); } catch { /* best-effort */ }
        try { _sd?.Dispose(); } catch { /* best-effort */ }
        try { _mdns?.Stop(); } catch { /* best-effort */ }
        try { _mdns?.Dispose(); } catch { /* best-effort */ }
        _sd = null;
        _mdns = null;
        _profile = null;
        Volatile.Write(ref _started, 0);
        return Task.CompletedTask;
    }

    /// <inheritdoc />
    public async ValueTask DisposeAsync()
    {
        if (Interlocked.CompareExchange(ref _disposed, 1, 0) != 0) return;
        await StopAsync().ConfigureAwait(false);
    }

    /// <summary>
    /// Enumerate the host's non-loopback IPv4 / IPv6 addresses suitable
    /// for advertising. Filters out tunneling adapters and link-local
    /// addresses without a scope ID.
    /// </summary>
    private static IEnumerable<IPAddress> LocalAddresses()
    {
        foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (nic.OperationalStatus != OperationalStatus.Up) continue;
            if (nic.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
            if (nic.NetworkInterfaceType == NetworkInterfaceType.Tunnel) continue;

            var props = nic.GetIPProperties();
            foreach (var ua in props.UnicastAddresses)
            {
                var addr = ua.Address;
                if (addr.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(addr))
                {
                    yield return addr;
                }
                else if (addr.AddressFamily == AddressFamily.InterNetworkV6 &&
                         !addr.IsIPv6LinkLocal && !addr.IsIPv6SiteLocal &&
                         !IPAddress.IsLoopback(addr))
                {
                    yield return addr;
                }
            }
        }
    }
}
