using System;
using System.Collections.Generic;

namespace DVAIBridge;

/// <summary>
/// A peer surfaced by the discovery layer — another device running
/// dvai-bridge that this device can (potentially) offload inference
/// requests to. Mirrors the shape of the TypeScript <c>Peer</c> type
/// in <c>@dvai-bridge/core</c> (<c>packages/dvai-bridge-core/src/discovery/types.ts</c>).
/// </summary>
public sealed record PeerInfo
{
    /// <summary>Stable per-install device ID of the peer.</summary>
    public required string DeviceId { get; init; }

    /// <summary>Human-readable hint (iOS device name, hostname, etc.).</summary>
    public required string DeviceName { get; init; }

    /// <summary>Library SemVer the peer is running.</summary>
    public required string DvaiVersion { get; init; }

    /// <summary>OpenAI-compatible base URL the peer's local server exposes.</summary>
    public required string BaseUrl { get; init; }

    /// <summary>Models the peer claims to have loaded right now.</summary>
    public IReadOnlyList<string> LoadedModels { get; init; } = Array.Empty<string>();

    /// <summary>
    /// Peer-reported capability map: <c>{ modelId → tok/s }</c>. Treat as
    /// advisory only; the offload decider re-probes a peer with a small
    /// reachability+decode test before its first real offload request.
    /// </summary>
    public IReadOnlyDictionary<string, double> Capability { get; init; } =
        new Dictionary<string, double>();

    /// <summary>
    /// Discovery source — useful for diagnostics and the structured-error
    /// response. One of <c>"mdns"</c>, <c>"static"</c>, <c>"rendezvous"</c>,
    /// or <c>"custom"</c>.
    /// </summary>
    public string Via { get; init; } = "mdns";

    /// <summary>Whether the peer's URL uses TLS.</summary>
    public bool Secure { get; init; }

    /// <summary>Last-seen unix ms — discovery sources update this.</summary>
    public long LastSeenAt { get; init; }
}
