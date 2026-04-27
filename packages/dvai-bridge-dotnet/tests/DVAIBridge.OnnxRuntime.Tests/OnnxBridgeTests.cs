using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using DVAIBridge.OnnxRuntime;
using Xunit;

namespace DVAIBridge.OnnxRuntime.Tests;

/// <summary>
/// Unit-level tests for <see cref="OnnxNativeBridge"/>. Avoids loading any
/// real ONNX model — those E2E flows are gated behind <c>DVAI_E2E=1</c>
/// in CI (the model fixture is ~700MB Llama-3.2-1B Q4 ONNX).
/// </summary>
public class OnnxBridgeTests
{
    [Fact]
    public void OnnxNativeBridge_CanInstantiate()
    {
        var instance = Activator.CreateInstance(typeof(OnnxNativeBridge), nonPublic: true);
        Assert.NotNull(instance);
    }

    [Fact]
    public async Task OnnxNativeBridge_RejectsNonOnnxBackend()
    {
        var bridge = (INativeBridge)Activator.CreateInstance(typeof(OnnxNativeBridge), nonPublic: true)!;
        var ex = await Assert.ThrowsAsync<DVAIBridgeException>(() =>
            bridge.StartAsync(new StartOptions { Backend = BackendKind.Llama, ModelPath = "/dev/null" }, CancellationToken.None));
        Assert.Equal(DVAIBridgeErrorKind.BackendUnavailable, ex.Kind);
    }

    [Fact]
    public async Task OnnxNativeBridge_RejectsMissingModelPath()
    {
        var bridge = (INativeBridge)Activator.CreateInstance(typeof(OnnxNativeBridge), nonPublic: true)!;
        var ex = await Assert.ThrowsAsync<DVAIBridgeException>(() =>
            bridge.StartAsync(new StartOptions { Backend = BackendKind.Onnx, ModelPath = null }, CancellationToken.None));
        Assert.Equal(DVAIBridgeErrorKind.ConfigurationInvalid, ex.Kind);
        Assert.Contains("ModelPath", ex.Message);
    }

    [Fact]
    public async Task OnnxNativeBridge_FailsOnMissingDirectory()
    {
        var bridge = (INativeBridge)Activator.CreateInstance(typeof(OnnxNativeBridge), nonPublic: true)!;
        var fakeDir = Path.Combine(Path.GetTempPath(), "dvai-test-nonexistent-" + Guid.NewGuid().ToString("N"));
        var ex = await Assert.ThrowsAsync<DVAIBridgeException>(() =>
            bridge.StartAsync(new StartOptions { Backend = BackendKind.Onnx, ModelPath = fakeDir }, CancellationToken.None));
        Assert.Equal(DVAIBridgeErrorKind.ConfigurationInvalid, ex.Kind);
    }

    [Fact]
    public async Task OnnxNativeBridge_FailsOnDirectoryMissingGenAIConfig()
    {
        var bridge = (INativeBridge)Activator.CreateInstance(typeof(OnnxNativeBridge), nonPublic: true)!;
        var dir = Path.Combine(Path.GetTempPath(), "dvai-test-empty-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            var ex = await Assert.ThrowsAsync<DVAIBridgeException>(() =>
                bridge.StartAsync(new StartOptions { Backend = BackendKind.Onnx, ModelPath = dir }, CancellationToken.None));
            Assert.Equal(DVAIBridgeErrorKind.ConfigurationInvalid, ex.Kind);
            Assert.Contains("genai_config.json", ex.Message);
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public async Task OnnxNativeBridge_StatusReportsNotRunningBeforeStart()
    {
        var bridge = (INativeBridge)Activator.CreateInstance(typeof(OnnxNativeBridge), nonPublic: true)!;
        var status = await bridge.GetStatusAsync(CancellationToken.None);
        Assert.False(status.Running);
    }

    [Fact]
    public void BackendKind_OnnxRoundTripsWireString()
    {
        Assert.Equal("onnx", BackendKind.Onnx.ToWireString());
        Assert.Equal(BackendKind.Onnx, BackendKindExtensions.FromWireString("onnx"));
    }
}
