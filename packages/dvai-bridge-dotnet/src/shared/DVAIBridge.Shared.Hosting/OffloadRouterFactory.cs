using System;
using System.Collections.Generic;

namespace DVAIBridge.Shared.Hosting;

/// <summary>
/// v3.2 — shared <see cref="OffloadRouter"/> construction used by every
/// .NET-host bridge (Desktop / MLNet / OnnxRuntime). Each native bridge
/// calls <see cref="BuildOffloadRouterIfEnabled"/> with its
/// <see cref="StartOptions"/>; the helper closes over
/// <see cref="DVAIBridge.Shared"/> for live peer + pairing data so the
/// router stays correct as the OffloadSession state evolves.
///
/// <para>
/// Returns <c>null</c> when offload isn't enabled — callers pass that
/// straight into <see cref="OpenAIServer"/>'s optional ctor parameter,
/// which makes the proxy middleware a no-op for non-offload starts.
/// </para>
/// </summary>
internal static class OffloadRouterFactory
{
    /// <summary>
    /// Build an <see cref="OffloadRouter"/> when
    /// <see cref="StartOptions.Offload"/> has <c>Enabled = true</c>.
    /// </summary>
    public static IOffloadRouter? BuildOffloadRouterIfEnabled(StartOptions opts)
    {
        if (opts.Offload is not { Enabled: true } cfg) return null;

        return new OffloadRouter(
            enabled: true,
            offloadOnlyMode: false,
            minLocalCapability: cfg.MinLocalCapability,
            peerProvider: () =>
            {
                var snapshot = DVAIBridge.Shared.Peers;
                var converted = new List<OffloadPeerInfo>(snapshot.Count);
                foreach (var p in snapshot)
                {
                    converted.Add(new OffloadPeerInfo(
                        DeviceId: p.DeviceId,
                        BaseUrl: p.BaseUrl,
                        Capability: p.Capability ?? new Dictionary<string, double>(),
                        LoadedModels: p.LoadedModels ?? new List<string>()));
                }
                return converted;
            },
            pairingLookup: async (peerDeviceId, lookupCt) =>
            {
                var pairing = await DVAIBridge.Shared
                    .GetActivePairingAsync(peerDeviceId, lookupCt)
                    .ConfigureAwait(false);
                return pairing is null
                    ? null
                    : new OffloadPairing(pairing.PeerDeviceId, pairing.PairingKey);
            },
            appId: "co.deepvoiceai.dvai-bridge.dotnet",
            selfDeviceId: DVAIBridge.Shared.DeviceId ?? "unknown");
    }
}
