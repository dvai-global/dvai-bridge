using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using DVAIBridge.Tests.Fakes;
using Xunit;

namespace DVAIBridge.Tests;

public class ProgressBroadcasterTests
{
    [Fact]
    public async Task ProgressEvents_YieldsEventsInOrder()
    {
        var fake = new FakeNativeBridge();
        await using var bridge = new DVAIBridge(fake);

        var collected = new List<ProgressEvent>();
        var cts = new CancellationTokenSource();

        var task = Task.Run(async () =>
        {
            await foreach (var ev in bridge.ProgressEvents.WithCancellation(cts.Token))
            {
                collected.Add(ev);
                if (collected.Count >= 3) break;
            }
        });

        // Give the consumer time to subscribe.
        await Task.Delay(50);

        fake.EmitProgress(new ProgressEvent(ProgressKind.Started, ProgressPhase.Start));
        fake.EmitProgress(new ProgressEvent(ProgressKind.Progress, ProgressPhase.Load, 50.0));
        fake.EmitProgress(new ProgressEvent(ProgressKind.Completed, ProgressPhase.Ready));

        await task;
        cts.Cancel();

        Assert.Equal(3, collected.Count);
        Assert.Equal(ProgressKind.Started, collected[0].Kind);
        Assert.Equal(ProgressKind.Progress, collected[1].Kind);
        Assert.Equal(50.0, collected[1].Percent);
        Assert.Equal(ProgressKind.Completed, collected[2].Kind);
    }

    [Fact]
    public async Task ProgressEvents_MultipleConsumers_EachReceiveEveryEvent()
    {
        var fake = new FakeNativeBridge();
        await using var bridge = new DVAIBridge(fake);

        var consumer1 = new List<ProgressEvent>();
        var consumer2 = new List<ProgressEvent>();
        var cts = new CancellationTokenSource();

        var t1 = Task.Run(async () =>
        {
            await foreach (var ev in bridge.ProgressEvents.WithCancellation(cts.Token))
            {
                consumer1.Add(ev);
                if (consumer1.Count >= 2) break;
            }
        });
        var t2 = Task.Run(async () =>
        {
            await foreach (var ev in bridge.ProgressEvents.WithCancellation(cts.Token))
            {
                consumer2.Add(ev);
                if (consumer2.Count >= 2) break;
            }
        });

        // Let both consumers subscribe before we emit.
        await Task.Delay(100);

        fake.EmitProgress(new ProgressEvent(ProgressKind.Started, ProgressPhase.Start));
        fake.EmitProgress(new ProgressEvent(ProgressKind.Completed, ProgressPhase.Ready));

        await Task.WhenAll(t1, t2).WaitAsync(System.TimeSpan.FromSeconds(2));
        cts.Cancel();

        Assert.Equal(2, consumer1.Count);
        Assert.Equal(2, consumer2.Count);
    }

    [Fact]
    public async Task ProgressEvents_CancellationExitsCleanly()
    {
        var fake = new FakeNativeBridge();
        await using var bridge = new DVAIBridge(fake);

        using var cts = new CancellationTokenSource();
        cts.CancelAfter(50);

        var collected = 0;
        await foreach (var _ in bridge.ProgressEvents.WithCancellation(cts.Token))
        {
            collected++;
        }
        // No assertion on count — the test passes if the loop exits without
        // an unhandled exception. (A throw on cancellation is acceptable
        // and would also fail the test if it escaped the try the harness uses;
        // OperationCanceledException doesn't escape `await foreach` inside
        // an `await foreach` over a cancellable IAsyncEnumerable.)
        Assert.Equal(0, collected);
    }

    [Fact]
    public async Task DisposeAsync_CompletesActiveConsumers()
    {
        var fake = new FakeNativeBridge();
        var bridge = new DVAIBridge(fake);

        var collected = 0;
        var task = Task.Run(async () =>
        {
            await foreach (var _ in bridge.ProgressEvents)
            {
                collected++;
            }
        });

        await Task.Delay(50);
        await bridge.DisposeAsync();
        await task.WaitAsync(System.TimeSpan.FromSeconds(2));

        Assert.Equal(0, collected);
    }
}
