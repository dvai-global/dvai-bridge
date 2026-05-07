using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Channels;
using System.Threading.Tasks;
using System.Runtime.CompilerServices;

namespace DVAIBridge.Pairing;

/// <summary>
/// Coordinates the host-app pairing UI with the persistent
/// <see cref="PairingStore"/>. Two entry points for the host app:
///
/// <list type="bullet">
///   <item>
///     <c>OnPairingRequest</c> async callback (mobile-friendly — see
///     <see cref="OffloadConfig.OnPairingRequest"/>).
///   </item>
///   <item>
///     <see cref="Requests"/> <c>IAsyncEnumerable&lt;PairingRequest&gt;</c>
///     stream (desktop-friendly — let SwiftUI / Avalonia / WinUI consume
///     and emit <see cref="PairingRequest.RespondAsync"/> calls).
///   </item>
/// </list>
///
/// <para>
/// Default behaviour (no callback supplied + no consumer of <c>Requests</c>):
/// deny all incoming pairings. Safe fallback — apps that haven't wired
/// UI shouldn't accidentally accept random LAN devices.
/// </para>
/// </summary>
public sealed class PairingPolicy : IDisposable
{
    private readonly PairingStore _store;
    private readonly Func<PeerInfo, Task<bool>>? _callback;
    private readonly TimeSpan _ttl;
    private readonly Channel<PairingRequest> _channel = Channel.CreateUnbounded<PairingRequest>(
        new UnboundedChannelOptions { SingleReader = false, SingleWriter = false });
    private int _activeReaders;
    private int _disposed;

    /// <summary>
    /// Construct the policy. Tests may pass a custom <paramref name="ttl"/>
    /// to verify expiry; production code uses the default 30 days.
    /// </summary>
    public PairingPolicy(
        PairingStore store,
        Func<PeerInfo, Task<bool>>? onPairingRequest = null,
        TimeSpan? ttl = null)
    {
        _store = store ?? throw new ArgumentNullException(nameof(store));
        _callback = onPairingRequest;
        _ttl = ttl ?? TimeSpan.FromDays(30);
    }

    /// <summary>The underlying store. Useful for revocation UIs.</summary>
    public PairingStore Store => _store;

    /// <summary>
    /// Stream of incoming pairing requests. Each request must be
    /// resolved by calling <see cref="PairingRequest.RespondAsync"/>.
    /// Multiple consumers receive a fan-out — but each request is
    /// answered by whichever consumer responds first.
    ///
    /// <para>
    /// Desktop UIs typically subscribe once at startup; mobile apps
    /// usually prefer the <see cref="OffloadConfig.OnPairingRequest"/>
    /// callback path.
    /// </para>
    /// </summary>
    public IAsyncEnumerable<PairingRequest> Requests => ReadAllAsync();

    private async IAsyncEnumerable<PairingRequest> ReadAllAsync(
        [EnumeratorCancellation] CancellationToken ct = default)
    {
        Interlocked.Increment(ref _activeReaders);
        try
        {
            await foreach (var req in _channel.Reader.ReadAllAsync(ct).ConfigureAwait(false))
            {
                yield return req;
            }
        }
        finally
        {
            Interlocked.Decrement(ref _activeReaders);
        }
    }

    /// <summary>
    /// Get an existing pairing for the peer, applying TTL expiry.
    /// Returns <c>null</c> if missing or expired (the latter case
    /// removes the stale entry from the store).
    /// </summary>
    public async Task<Pairing?> GetActiveAsync(string peerDeviceId, CancellationToken ct = default)
    {
        var existing = await _store.GetAsync(peerDeviceId, ct).ConfigureAwait(false);
        if (existing is null) return null;

        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        if (now - existing.LastUsedAt > (long)_ttl.TotalMilliseconds)
        {
            await _store.RemoveAsync(peerDeviceId, ct).ConfigureAwait(false);
            return null;
        }
        return existing;
    }

    /// <summary>
    /// Process an incoming pairing request. If we already have an active
    /// pairing for this peer, reuse it (and bump <c>LastUsedAt</c>).
    /// Otherwise consult the host app — first the
    /// <see cref="OffloadConfig.OnPairingRequest"/> callback (if any),
    /// then any subscribers of <see cref="Requests"/> (if any).
    ///
    /// <para>
    /// Returns the active <see cref="Pairing"/> on approval; throws
    /// <see cref="InvalidOperationException"/> when no host hook
    /// approved it. The callback path takes precedence when both are
    /// configured.
    /// </para>
    /// </summary>
    public async Task<Pairing> ApproveOrFetchAsync(PeerInfo peer, string via, CancellationToken ct = default)
    {
        if (peer is null) throw new ArgumentNullException(nameof(peer));

        var existing = await GetActiveAsync(peer.DeviceId, ct).ConfigureAwait(false);
        if (existing is not null)
        {
            var bumped = existing with { LastUsedAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() };
            await _store.SetAsync(bumped, ct).ConfigureAwait(false);
            return bumped;
        }

        bool approved = false;

        if (_callback is { } cb)
        {
            approved = await cb(peer).ConfigureAwait(false);
        }
        else if (Volatile.Read(ref _activeReaders) > 0)
        {
            // Try the streaming path: emit a PairingRequest and await its decision.
            // Only used when at least one consumer has subscribed to Requests —
            // otherwise the request would queue indefinitely.
            var req = new PairingRequest(peer.DeviceId, peer.DeviceName, via);
            if (_channel.Writer.TryWrite(req))
            {
                using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct);
                approved = await req.Decision.WaitAsync(linked.Token).ConfigureAwait(false);
            }
        }

        if (!approved)
        {
            throw new InvalidOperationException(
                $"[DVAI/pairing] denied: peer {peer.DeviceId} ({peer.DeviceName})" +
                (_callback is null ? " (no OnPairingRequest callback supplied)" : string.Empty));
        }

        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var fresh = new Pairing(
            PeerDeviceId: peer.DeviceId,
            PeerDeviceName: peer.DeviceName,
            PairingKey: PairingHandshake.GeneratePairingKey(),
            PairedAt: now,
            LastUsedAt: now,
            Via: via);

        await _store.SetAsync(fresh, ct).ConfigureAwait(false);
        return fresh;
    }

    /// <summary>Mark a pairing as used (bumps <c>LastUsedAt</c>).</summary>
    public async Task TouchAsync(string peerDeviceId, CancellationToken ct = default)
    {
        var existing = await _store.GetAsync(peerDeviceId, ct).ConfigureAwait(false);
        if (existing is null) return;
        var bumped = existing with { LastUsedAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() };
        await _store.SetAsync(bumped, ct).ConfigureAwait(false);
    }

    /// <summary>Revoke a pairing by peer ID.</summary>
    public Task RevokeAsync(string peerDeviceId, CancellationToken ct = default) =>
        _store.RemoveAsync(peerDeviceId, ct);

    /// <summary>
    /// Test-only entry-point — synthesise a request as if it came from
    /// the discovery layer. Useful for asserting the streaming +
    /// callback paths without touching the network.
    /// </summary>
    internal bool TryEnqueueRequest(PairingRequest req) => _channel.Writer.TryWrite(req);

    /// <inheritdoc />
    public void Dispose()
    {
        if (System.Threading.Interlocked.CompareExchange(ref _disposed, 1, 0) != 0) return;
        _channel.Writer.TryComplete();
    }
}
