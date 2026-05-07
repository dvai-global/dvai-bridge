using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using DVAIBridge.Capability;
using DVAIBridge.Pairing;

namespace DVAIBridge;

/// <summary>
/// Owns the runtime state for the offload pipeline:
/// <see cref="CapabilityCache"/>, <see cref="PairingPolicy"/>, the
/// discovery layer, and any pre-known peers passed via
/// <see cref="OffloadConfig.KnownPeers"/>. Created by the facade when
/// <see cref="OffloadConfig.Enabled"/> is <c>true</c> and torn down on
/// <see cref="DVAIBridge.StopAsync"/>.
/// </summary>
internal sealed class OffloadSession : IAsyncDisposable
{
    private readonly OffloadConfig _config;
    private readonly IDiscovery? _discovery;
    private readonly Dictionary<string, PeerInfo> _knownPeers;
    private int _disposed;

    public CapabilityCache CapabilityCache { get; }
    public PairingPolicy PairingPolicy { get; }
    public string DeviceId { get; }
    public IReadOnlyList<PeerInfo> KnownPeers => new List<PeerInfo>(_knownPeers.Values);
    public IDiscovery? Discovery => _discovery;

    public OffloadSession(
        OffloadConfig config,
        CapabilityCache capabilityCache,
        PairingPolicy pairingPolicy,
        IDiscovery? discovery,
        string deviceId)
    {
        _config = config ?? throw new ArgumentNullException(nameof(config));
        CapabilityCache = capabilityCache ?? throw new ArgumentNullException(nameof(capabilityCache));
        PairingPolicy = pairingPolicy ?? throw new ArgumentNullException(nameof(pairingPolicy));
        _discovery = discovery;
        DeviceId = deviceId ?? throw new ArgumentNullException(nameof(deviceId));

        _knownPeers = new Dictionary<string, PeerInfo>();
        foreach (var p in config.KnownPeers)
        {
            _knownPeers[p.DeviceId] = p;
        }
    }

    /// <summary>
    /// Test-only hook — invoked at the end of <see cref="StartAsync"/> with
    /// the freshly-constructed session. Lets test discovery factories grab
    /// a reference to the session so they can drive the pairing-policy
    /// streaming surface without having to reach through internal state.
    /// </summary>
    [System.Runtime.CompilerServices.CompilerGenerated]
    internal static Action<OffloadSession>? OnSessionStartedForTests;

    /// <summary>
    /// Construct + start an offload session. The factory boots the
    /// discovery layer (best-effort — discovery failures are logged but
    /// don't fail the bridge start) and prepares the capability cache.
    /// </summary>
    public static async Task<OffloadSession> StartAsync(
        OffloadConfig config,
        IDiscoveryFactory? discoveryFactory,
        CancellationToken ct)
    {
        var deviceId = Capability.DeviceId.Resolve();
        var cache = CapabilityCache.CreateDefault();
        var store = PairingStore.CreateDefault();
        var policy = new PairingPolicy(store, config.OnPairingRequest);

        IDiscovery? discovery = null;
        if (config.DiscoverLAN && discoveryFactory is not null)
        {
            try
            {
                discovery = discoveryFactory.Create(deviceId);
                await discovery.StartAsync(ct).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                // Discovery init must never bring down the bridge.
                System.Diagnostics.Debug.WriteLine(
                    $"[DVAIBridge.Offload] discovery init failed: {ex.Message}");
                discovery = null;
            }
        }

        var session = new OffloadSession(config, cache, policy, discovery, deviceId);
        try { OnSessionStartedForTests?.Invoke(session); } catch { /* test-only seam */ }
        return session;
    }

    /// <summary>
    /// Combined view of known peers + discovered peers. Discovery
    /// surfaces wins on key collisions (fresher information).
    /// </summary>
    public IReadOnlyList<PeerInfo> Peers
    {
        get
        {
            var result = new Dictionary<string, PeerInfo>(_knownPeers);
            if (_discovery is { } d)
            {
                foreach (var p in d.Peers) result[p.DeviceId] = p;
            }
            return new List<PeerInfo>(result.Values);
        }
    }

    /// <inheritdoc />
    public async ValueTask DisposeAsync()
    {
        if (Interlocked.CompareExchange(ref _disposed, 1, 0) != 0) return;
        if (_discovery is not null)
        {
            try { await _discovery.StopAsync(default).ConfigureAwait(false); }
            catch { /* best-effort teardown */ }
        }
        PairingPolicy.Dispose();
    }
}

/// <summary>
/// Internal factory for the per-platform <see cref="IDiscovery"/>
/// implementation. The desktop NuGet plugs <c>MdnsDiscoveryFactory</c>
/// into the facade via reflection at startup; mobile slices delegate
/// to the native binding via their own factory.
/// </summary>
internal interface IDiscoveryFactory
{
    /// <summary>Create a fresh discovery instance for this device.</summary>
    IDiscovery Create(string deviceId);
}
