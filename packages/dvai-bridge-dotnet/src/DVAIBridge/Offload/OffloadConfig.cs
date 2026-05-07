using System;
using System.Collections.Generic;
using System.Threading.Tasks;

namespace DVAIBridge;

/// <summary>
/// Distributed-inference (offload) configuration. Optionally attached to
/// <see cref="StartOptions.Offload"/>. When <see cref="Enabled"/> is
/// <c>true</c>, the bridge runs LAN discovery (mDNS) for sibling devices
/// and surfaces a <see cref="DVAIBridge.PairingRequests"/> stream for
/// host-app UI. Mirrors the TypeScript <c>OffloadConfig</c> in
/// <c>@dvai-bridge/core</c>.
/// </summary>
public sealed record OffloadConfig
{
    /// <summary>Master switch. Default <c>false</c>; offload is opt-in at v3.0.</summary>
    public bool Enabled { get; init; } = false;

    /// <summary>Run mDNS to discover LAN peers. Default <c>true</c>.</summary>
    public bool DiscoverLAN { get; init; } = true;

    /// <summary>
    /// Below this tok/s estimate of local capability, the offload decider
    /// looks for a peer. Default <c>10</c> tok/s.
    /// </summary>
    public double MinLocalCapability { get; init; } = 10.0;

    /// <summary>
    /// Optional rendezvous-server URL — enables the internet path when set.
    /// Should be a <c>wss://</c> or <c>https://</c> URL pointing at a
    /// self-hosted rendezvous deployment.
    /// </summary>
    public Uri? RendezvousUrl { get; init; }

    /// <summary>
    /// Optional pre-known peers (skip discovery for these). Useful for
    /// kiosk / fleet deployments where the peer addresses are known in
    /// advance.
    /// </summary>
    public IReadOnlyList<PeerInfo> KnownPeers { get; init; } = Array.Empty<PeerInfo>();

    /// <summary>
    /// Hook to surface a pairing-request UI to the host app. Returning
    /// <c>true</c> approves the pairing; <c>false</c> denies. Default:
    /// deny (no callback supplied). On desktop, prefer the streaming
    /// <see cref="DVAIBridge.PairingRequests"/> surface; mobile callers
    /// commonly use this callback because they don't host the UI thread
    /// the way desktop apps do.
    /// </summary>
    public Func<PeerInfo, Task<bool>>? OnPairingRequest { get; init; }
}
