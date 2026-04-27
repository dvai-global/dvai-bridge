using System;
using System.Threading;
using System.Threading.Tasks;
using DVAIBridge.Tests.Fakes;
using Xunit;

namespace DVAIBridge.Tests;

public class DVAIBridgeFacadeTests
{
    [Fact]
    public async Task StartAsync_ForwardsToNativeAndReturnsBoundServer()
    {
        var fake = new FakeNativeBridge
        {
            StartHandler = (opts, _) =>
                Task.FromResult(new BoundServer("http://127.0.0.1:9000/v1", 9000, opts.Backend, "real-model")),
        };
        await using var bridge = new DVAIBridge(fake);

        var server = await bridge.StartAsync(new StartOptions
        {
            Backend = BackendKind.Llama,
            ModelPath = "/tmp/m.gguf",
        });

        Assert.Equal(1, fake.StartCallCount);
        Assert.Equal("http://127.0.0.1:9000/v1", server.BaseUrl);
        Assert.Equal(9000, server.Port);
        Assert.Equal(BackendKind.Llama, server.Backend);
        Assert.Equal("real-model", server.ModelId);
    }

    [Fact]
    public async Task StartAsync_PropagatesDVAIBridgeException()
    {
        var fake = new FakeNativeBridge
        {
            StartHandler = (opts, _) =>
                Task.FromException<BoundServer>(DVAIBridgeException.AlreadyStarted(opts.Backend, "http://127.0.0.1:8080/v1")),
        };
        await using var bridge = new DVAIBridge(fake);

        var ex = await Assert.ThrowsAsync<DVAIBridgeException>(() =>
            bridge.StartAsync(new StartOptions { Backend = BackendKind.Llama }));

        Assert.Equal(DVAIBridgeErrorKind.AlreadyStarted, ex.Kind);
        Assert.Equal("http://127.0.0.1:8080/v1", ex.Details["baseUrl"]);
    }

    [Fact]
    public async Task StartAsync_WrapsArbitraryExceptionsAsBackendError()
    {
        var fake = new FakeNativeBridge
        {
            StartHandler = (_, _) => Task.FromException<BoundServer>(new InvalidOperationException("bus driver")),
        };
        await using var bridge = new DVAIBridge(fake);

        var ex = await Assert.ThrowsAsync<DVAIBridgeException>(() =>
            bridge.StartAsync(new StartOptions { Backend = BackendKind.Llama }));

        Assert.Equal(DVAIBridgeErrorKind.BackendError, ex.Kind);
        Assert.IsType<InvalidOperationException>(ex.InnerException);
        Assert.Equal("bus driver", ex.Details["underlying"]);
    }

    [Fact]
    public async Task StartAsync_RejectsAndroidOnlyBackendOnIOS()
    {
        // We can't actually flip OperatingSystem.IsIOS() in a unit test, so
        // we exercise the dispatch only on the platform the test runs on.
        // On non-iOS / non-Android (Linux/Windows test runners), the facade
        // throws BackendUnavailable for *every* backend with the
        // "no native binding for this platform" reason.
        var fake = new FakeNativeBridge();
        await using var bridge = new DVAIBridge(fake);

        if (OperatingSystem.IsIOS())
        {
            var ex = await Assert.ThrowsAsync<DVAIBridgeException>(() =>
                bridge.StartAsync(new StartOptions { Backend = BackendKind.MediaPipe }));
            Assert.Equal(DVAIBridgeErrorKind.BackendUnavailable, ex.Kind);
            Assert.Contains("Android-only", ex.Message);
        }
        else if (OperatingSystem.IsAndroid())
        {
            var ex = await Assert.ThrowsAsync<DVAIBridgeException>(() =>
                bridge.StartAsync(new StartOptions { Backend = BackendKind.Foundation }));
            Assert.Equal(DVAIBridgeErrorKind.BackendUnavailable, ex.Kind);
            Assert.Contains("iOS-only", ex.Message);
        }
        else
        {
            // Desktop / CI: every backend rejected with the no-native-binding reason.
            var ex = await Assert.ThrowsAsync<DVAIBridgeException>(() =>
                bridge.StartAsync(new StartOptions { Backend = BackendKind.Auto }));
            Assert.Equal(DVAIBridgeErrorKind.BackendUnavailable, ex.Kind);
            Assert.Contains("only ship for iOS and Android", ex.Message);
        }
    }

    [Fact]
    public async Task StopAsync_ForwardsToNative()
    {
        var fake = new FakeNativeBridge();
        await using var bridge = new DVAIBridge(fake);

        await bridge.StopAsync();

        Assert.Equal(1, fake.StopCallCount);
    }

    [Fact]
    public async Task GetStatusAsync_ForwardsToNative()
    {
        var fake = new FakeNativeBridge
        {
            StatusHandler = _ => Task.FromResult(
                new StatusInfo(true, "http://127.0.0.1:1/v1", 1, BackendKind.Llama, "model-x")),
        };
        await using var bridge = new DVAIBridge(fake);

        var status = await bridge.GetStatusAsync();

        Assert.True(status.Running);
        Assert.Equal(1, fake.StatusCallCount);
        Assert.Equal("model-x", status.ModelId);
    }

    [Fact]
    public async Task DownloadModelAsync_ForwardsToNative()
    {
        var fake = new FakeNativeBridge
        {
            DownloadHandler = (opts, _) =>
                Task.FromResult(new DownloadResult($"/var/cache/{opts.DestFilename ?? "model"}", opts.Sha256, 2048L)),
        };
        await using var bridge = new DVAIBridge(fake);

        var result = await bridge.DownloadModelAsync(new DownloadOptions(
            Url: "https://example.test/m.gguf",
            Sha256: "abcd",
            DestFilename: "m.gguf"));

        Assert.Equal(1, fake.DownloadCallCount);
        Assert.Equal("/var/cache/m.gguf", result.Path);
        Assert.Equal("abcd", result.Sha256);
        Assert.Equal(2048L, result.SizeBytes);
    }

    [Fact]
    public async Task GetStateAsync_DerivesFromStatusAndLastError()
    {
        var fake = new FakeNativeBridge
        {
            StartHandler = (_, _) => Task.FromException<BoundServer>(DVAIBridgeException.ModelLoadFailed("bad gguf")),
            StatusHandler = _ => Task.FromResult(
                new StatusInfo(false, null, null, null, null)),
        };
        await using var bridge = new DVAIBridge(fake);

        // Force the LastError path.
        await Assert.ThrowsAsync<DVAIBridgeException>(() =>
            bridge.StartAsync(new StartOptions { Backend = BackendKind.Llama }));

        var state = await bridge.GetStateAsync();

        Assert.False(state.IsReady);
        Assert.Null(state.BaseUrl);
        Assert.NotNull(state.LastError);
        Assert.Equal(DVAIBridgeErrorKind.ModelLoadFailed, state.LastError!.Kind);
    }

    [Fact]
    public async Task StartAsync_ClearsLastErrorOnSuccess()
    {
        var fakeFail = new FakeNativeBridge
        {
            StartHandler = (_, _) => Task.FromException<BoundServer>(DVAIBridgeException.ModelLoadFailed("first attempt")),
        };
        await using var bridge = new DVAIBridge(fakeFail);

        await Assert.ThrowsAsync<DVAIBridgeException>(() =>
            bridge.StartAsync(new StartOptions { Backend = BackendKind.Llama }));
        var stateBefore = await bridge.GetStateAsync();
        Assert.NotNull(stateBefore.LastError);

        // Replace the handler and try again.
        fakeFail.StartHandler = (opts, _) =>
            Task.FromResult(new BoundServer("http://127.0.0.1:9000/v1", 9000, opts.Backend, "ok"));

        await bridge.StartAsync(new StartOptions { Backend = BackendKind.Llama });
        var stateAfter = await bridge.GetStateAsync();
        Assert.Null(stateAfter.LastError);
    }
}
