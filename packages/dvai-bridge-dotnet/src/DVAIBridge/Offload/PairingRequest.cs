using System.Threading;
using System.Threading.Tasks;

namespace DVAIBridge;

/// <summary>
/// An incoming pairing request emitted by the
/// <see cref="DVAIBridge.PairingRequests"/> stream. Surface the peer's
/// device name to the user, then call
/// <see cref="RespondAsync(bool, CancellationToken)"/> with the user's
/// approve / deny decision.
/// </summary>
public sealed class PairingRequest
{
    private readonly TaskCompletionSource<bool> _tcs;
    private int _responded;

    /// <summary>Stable per-install device ID of the peer requesting pairing.</summary>
    public string PeerDeviceId { get; }

    /// <summary>Friendly device name surfaced by the peer (display in UI).</summary>
    public string PeerDeviceName { get; }

    /// <summary>Discovery source — <c>"lan-handshake"</c> or <c>"rendezvous-qr"</c>.</summary>
    public string Via { get; }

    internal Task<bool> Decision => _tcs.Task;

    /// <summary>
    /// Internal constructor — only the pairing policy creates pairing
    /// requests. Host apps consume them via
    /// <see cref="DVAIBridge.PairingRequests"/>.
    /// </summary>
    internal PairingRequest(string peerDeviceId, string peerDeviceName, string via)
    {
        PeerDeviceId = peerDeviceId;
        PeerDeviceName = peerDeviceName;
        Via = via;
        _tcs = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
    }

    /// <summary>
    /// Respond to the pairing request. Idempotent — only the first
    /// response is honoured; subsequent calls return immediately. Pair
    /// once per <see cref="PeerDeviceId"/>; the policy persists the
    /// approval to disk.
    /// </summary>
    /// <param name="approved">
    /// <c>true</c> if the user approved the pairing; <c>false</c> to deny.
    /// </param>
    /// <param name="ct">Cancels the wait — rarely used.</param>
    public Task RespondAsync(bool approved, CancellationToken ct = default)
    {
        if (System.Threading.Interlocked.CompareExchange(ref _responded, 1, 0) == 0)
        {
            _tcs.TrySetResult(approved);
        }
        return Task.CompletedTask;
    }
}
