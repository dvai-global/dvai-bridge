using System.Text.Json.Serialization;

namespace DVAIBridge.Pairing;

/// <summary>
/// An authenticated trust relationship between this device and a peer.
/// Established once via the handshake flow, then reused for all
/// subsequent offload requests via HMAC-signed headers. Mirrors the
/// TypeScript <c>Pairing</c> shape in <c>@dvai-bridge/core</c>.
/// </summary>
/// <param name="PeerDeviceId">Stable per-install device ID of the peer.</param>
/// <param name="PeerDeviceName">Friendly name for the user UI (revoke / re-pair).</param>
/// <param name="PairingKey">Shared 256-bit pairing key (base64-url encoded). Used for HMAC.</param>
/// <param name="PairedAt">Unix milliseconds when the pairing was first established.</param>
/// <param name="LastUsedAt">Last time this pairing was used for an offload request.</param>
/// <param name="Via">Pairing source — informational. <c>"lan-handshake"</c> or <c>"rendezvous-qr"</c>.</param>
public sealed record Pairing(
    [property: JsonPropertyName("peerDeviceId")] string PeerDeviceId,
    [property: JsonPropertyName("peerDeviceName")] string PeerDeviceName,
    [property: JsonPropertyName("pairingKey")] string PairingKey,
    [property: JsonPropertyName("pairedAt")] long PairedAt,
    [property: JsonPropertyName("lastUsedAt")] long LastUsedAt,
    [property: JsonPropertyName("via")] string Via);
