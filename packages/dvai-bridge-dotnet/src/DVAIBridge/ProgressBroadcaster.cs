using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Threading.Channels;
using System.Threading.Tasks;

namespace DVAIBridge;

/// <summary>
/// Multicast progress broadcaster — the bridge between the single-writer
/// callback emitted by <see cref="INativeBridge.SubscribeProgress(Action{ProgressEvent})"/>
/// and the fan-out <see cref="IAsyncEnumerable{T}"/> consumed by app code.
///
/// <para>
/// <b>Multi-consumer caveat:</b> a bare <c>Channel&lt;T&gt;.CreateUnbounded</c>
/// fans <i>events</i> out to <i>multiple readers</i> by competition — each
/// dequeue is observed by exactly one reader. That's wrong for a progress
/// broadcaster (every UI subscriber wants every event). We fix the contract
/// by allocating a dedicated bounded <see cref="Channel{T}"/> per
/// subscriber and writing every event to all of them in
/// <see cref="Emit(ProgressEvent)"/>.
/// </para>
///
/// <para>
/// We deliberately avoid taking a dependency on <c>System.Reactive</c>
/// (40 KB+ transitive bloat) or <c>System.Threading.Tasks.Dataflow</c>'s
/// <c>BroadcastBlock&lt;T&gt;</c> (overkill for this fan-out shape). The
/// per-subscriber-channel pattern keeps allocations bounded
/// (<c>BoundedChannelOptions { Capacity = 64, FullMode = DropOldest }</c>:
/// a slow consumer only loses old events, never blocks the writer or other
/// consumers).
/// </para>
/// </summary>
internal sealed class ProgressBroadcaster : IDisposable
{
    // Note: ConcurrentDictionary keyed by Channel<T> identity gives us a
    // thread-safe set with O(1) add/remove and a lock-free read in Emit.
    private readonly ConcurrentDictionary<Channel<ProgressEvent>, byte> _subscribers = new();
    private bool _disposed;

    /// <summary>
    /// Fan an event out to every active subscriber. Called from the
    /// callback registered by <see cref="DVAIBridge"/> against
    /// <see cref="INativeBridge.SubscribeProgress(Action{ProgressEvent})"/>.
    /// </summary>
    public void Emit(ProgressEvent ev)
    {
        if (_disposed)
        {
            return;
        }

        // Snapshot the keys to avoid racing concurrent Subscribe / Dispose calls
        // that could otherwise mutate the dictionary mid-iteration.
        // ConcurrentDictionary.Keys materializes a snapshot atomically.
        var snapshot = _subscribers.Keys;
        foreach (var ch in snapshot)
        {
            // BoundedChannelFullMode.DropOldest means TryWrite always succeeds
            // (we kicked out the oldest item when at capacity). No back-pressure
            // on the writer; no blocking. TryWrite returns false (no throw) if
            // the channel is already completed by a parallel Dispose() — safe.
            ch.Writer.TryWrite(ev);
        }
    }

    /// <summary>
    /// Open an async stream of progress events. Every consumer who calls
    /// this gets a fresh underlying <see cref="Channel{T}"/>; every
    /// <see cref="Emit(ProgressEvent)"/> fans out to all of them.
    /// </summary>
    /// <param name="ct">Cancels the consumer's enumeration without affecting other consumers.</param>
    public async IAsyncEnumerable<ProgressEvent> Subscribe(
        [EnumeratorCancellation] CancellationToken ct = default)
    {
        var ch = Channel.CreateBounded<ProgressEvent>(new BoundedChannelOptions(64)
        {
            FullMode = BoundedChannelFullMode.DropOldest,
            SingleReader = true,
            SingleWriter = false, // Emit() is thread-safe; multiple natives may race
        });

        _subscribers[ch] = 0;
        try
        {
            // Drain the channel until the consumer cancels OR Dispose() completes
            // the writer side. We catch OCE here so a cancellation bubbles out as
            // a clean iterator-exit (yield-break semantics) rather than a thrown
            // exception escaping `await foreach` — the canonical pattern is to
            // treat ct.IsCancellationRequested as the natural-end-of-stream
            // signal in a multicast IAsyncEnumerable.
            //
            // Note: we cannot use try/catch around `yield return` directly,
            // so we wrap the iteration via a local async enumerator that
            // swallows the cancellation, then yield from it.
            var enumerator = ReadCancellableAsync(ch, ct).GetAsyncEnumerator(ct);
            try
            {
                while (true)
                {
                    bool moved;
                    try
                    {
                        moved = await enumerator.MoveNextAsync().ConfigureAwait(false);
                    }
                    catch (OperationCanceledException) when (ct.IsCancellationRequested)
                    {
                        // Cancellation is the intended exit path — yield-break.
                        yield break;
                    }
                    if (!moved) yield break;
                    yield return enumerator.Current;
                }
            }
            finally
            {
                await enumerator.DisposeAsync().ConfigureAwait(false);
            }
        }
        finally
        {
            _subscribers.TryRemove(ch, out _);
            ch.Writer.TryComplete();
        }
    }

    /// <summary>
    /// Plain async-iterator over the channel reader. Separated from
    /// <see cref="Subscribe(CancellationToken)"/> so the calling iterator can
    /// catch <see cref="OperationCanceledException"/> without losing the
    /// `yield return`-bearing scope.
    /// </summary>
    private static async IAsyncEnumerable<ProgressEvent> ReadCancellableAsync(
        Channel<ProgressEvent> ch,
        [EnumeratorCancellation] CancellationToken ct)
    {
        await foreach (var ev in ch.Reader.ReadAllAsync(ct).ConfigureAwait(false))
        {
            yield return ev;
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        foreach (var ch in _subscribers.Keys)
        {
            ch.Writer.TryComplete();
        }
        _subscribers.Clear();
    }
}
