using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace DVAIBridge;

/// <summary>
/// Event payload emitted by <see cref="IDiscovery.Subscribe"/>. Mirrors
/// the TS <c>DiscoveryEvent</c> union — but expressed as a single
/// payload type with a discriminator so we play well with idiomatic
/// C# event consumers.
/// </summary>
/// <param name="Type">
/// One of <c>"peer-up"</c>, <c>"peer-down"</c>, or <c>"error"</c>.
/// </param>
/// <param name="Peer">
/// The peer for <c>"peer-up"</c> events; <c>null</c> for the others.
/// </param>
/// <param name="DeviceId">
/// The peer's device ID for <c>"peer-down"</c>; <c>null</c> for the others.
/// </param>
/// <param name="Message">
/// Diagnostic for <c>"error"</c>; <c>null</c> for the others.
/// </param>
public sealed record DiscoveryEvent(
    string Type,
    PeerInfo? Peer = null,
    string? DeviceId = null,
    string? Message = null);

/// <summary>
/// The contract every discovery source implements. Used by the offload
/// pipeline; the facade uses the desktop / iOS / Android slices'
/// concrete implementations at runtime.
/// </summary>
public interface IDiscovery
{
    /// <summary>Begin discovering. Idempotent.</summary>
    Task StartAsync(CancellationToken ct = default);

    /// <summary>Stop and release resources. Idempotent.</summary>
    Task StopAsync(CancellationToken ct = default);

    /// <summary>Snapshot of currently-known peers.</summary>
    IReadOnlyList<PeerInfo> Peers { get; }

    /// <summary>
    /// Subscribe to discovery events. Returns an <see cref="IDisposable"/>
    /// — disposing it unsubscribes the handler.
    /// </summary>
    IDisposable Subscribe(Action<DiscoveryEvent> listener);
}

/// <summary>
/// Service-type advertised on mDNS for dvai-bridge instances. Matches
/// <c>MDNS_SERVICE_TYPE</c> in <c>@dvai-bridge/core/src/discovery/types.ts</c>.
/// </summary>
public static class DiscoveryConstants
{
    /// <summary>The mDNS service type. Always this exact value.</summary>
    public const string MdnsServiceType = "_dvai-bridge._tcp.local";
}
