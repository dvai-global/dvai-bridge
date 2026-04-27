using System.Threading.Tasks;
using DVAIBridge.Tests.Fakes;
using Xunit;

namespace DVAIBridge.Tests;

public class PlatformExceptionMappingTests
{
    [Fact]
    public void AlreadyStarted_PopulatesDetails()
    {
        var ex = DVAIBridgeException.AlreadyStarted(BackendKind.Llama, "http://127.0.0.1:1/v1");
        Assert.Equal(DVAIBridgeErrorKind.AlreadyStarted, ex.Kind);
        Assert.Equal(BackendKind.Llama, ex.Details["backend"]);
        Assert.Equal("http://127.0.0.1:1/v1", ex.Details["baseUrl"]);
    }

    [Fact]
    public void ConfigurationInvalid_PopulatesDetails()
    {
        var ex = DVAIBridgeException.ConfigurationInvalid("bad path");
        Assert.Equal(DVAIBridgeErrorKind.ConfigurationInvalid, ex.Kind);
        Assert.Equal("bad path", ex.Details["reason"]);
    }

    [Fact]
    public void BackendUnavailable_PopulatesDetails()
    {
        var ex = DVAIBridgeException.BackendUnavailable(BackendKind.MLX, "iOS-only");
        Assert.Equal(DVAIBridgeErrorKind.BackendUnavailable, ex.Kind);
        Assert.Equal(BackendKind.MLX, ex.Details["backend"]);
        Assert.Equal("iOS-only", ex.Details["reason"]);
    }

    [Fact]
    public void ChecksumMismatch_PopulatesDetails()
    {
        var ex = DVAIBridgeException.ChecksumMismatch("aaa", "bbb");
        Assert.Equal(DVAIBridgeErrorKind.ChecksumMismatch, ex.Kind);
        Assert.Equal("aaa", ex.Details["expected"]);
        Assert.Equal("bbb", ex.Details["got"]);
    }

    [Fact]
    public async Task NativeException_RoundTripsToFacade()
    {
        var fake = new FakeNativeBridge
        {
            DownloadHandler = (_, _) => Task.FromException<DownloadResult>(
                DVAIBridgeException.ChecksumMismatch("expected-sha", "got-sha")),
        };
        await using var bridge = new DVAIBridge(fake);

        var ex = await Assert.ThrowsAsync<DVAIBridgeException>(() =>
            bridge.DownloadModelAsync(new DownloadOptions("https://x", "expected-sha")));

        Assert.Equal(DVAIBridgeErrorKind.ChecksumMismatch, ex.Kind);
        Assert.Equal("expected-sha", ex.Details["expected"]);
        Assert.Equal("got-sha", ex.Details["got"]);
    }
}
