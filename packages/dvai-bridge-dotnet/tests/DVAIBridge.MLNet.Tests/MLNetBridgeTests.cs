using System;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using DVAIBridge.MLNet;
using Xunit;

namespace DVAIBridge.MLNet.Tests;

/// <summary>
/// Unit-level tests for <see cref="MLNetNativeBridge"/>. Mirrors the shape
/// of <c>OnnxBridgeTests</c> (we reuse the same reflection-via-internal
/// pattern enabled by the InternalsVisibleTo grant in
/// <c>DVAIBridge.MLNet/AssemblyInfo.cs</c>).
///
/// <para>We intentionally skip loading a real ONNX model — the
/// <c>OnnxScoringEstimator.Fit(...)</c> call inside
/// <see cref="MLNetInferenceEngine"/> would pull in a multi-hundred-MB
/// fixture and exercise native ORT. Those E2E flows are gated behind
/// <c>DVAI_E2E=1</c> in a separate desktop CI job. These tests cover the
/// validation / dispatch / configuration paths only.</para>
/// </summary>
public class MLNetBridgeTests
{
    [Fact]
    public void MLNetNativeBridge_CanInstantiate()
    {
        // Activator.CreateInstance(nonPublic: true) is the same path
        // PlatformBridgeFactory uses for runtime resolution.
        var instance = Activator.CreateInstance(typeof(MLNetNativeBridge), nonPublic: true);
        Assert.NotNull(instance);
    }

    [Fact]
    public async Task MLNetNativeBridge_RejectsBackendKindOnnx_WithCorrectError()
    {
        // Wrong-backend dispatch error: the MLNet slice should reject any
        // non-MLNet (and non-Auto) backend with BackendUnavailable. ONNX is
        // the most-likely-confused-with case (same underlying ORT natives,
        // different facade contract).
        var bridge = (INativeBridge)Activator.CreateInstance(typeof(MLNetNativeBridge), nonPublic: true)!;
        var ex = await Assert.ThrowsAsync<DVAIBridgeException>(() =>
            bridge.StartAsync(new StartOptions { Backend = BackendKind.Onnx, ModelPath = "/dev/null" }, CancellationToken.None));
        Assert.Equal(DVAIBridgeErrorKind.BackendUnavailable, ex.Kind);
        Assert.Contains("MLNetNativeBridge only handles BackendKind.MLNet", ex.Message);
    }

    [Fact]
    public async Task MLNetNativeBridge_RejectsMissingModelPath()
    {
        var bridge = (INativeBridge)Activator.CreateInstance(typeof(MLNetNativeBridge), nonPublic: true)!;
        var ex = await Assert.ThrowsAsync<DVAIBridgeException>(() =>
            bridge.StartAsync(new StartOptions { Backend = BackendKind.MLNet, ModelPath = null }, CancellationToken.None));
        Assert.Equal(DVAIBridgeErrorKind.ConfigurationInvalid, ex.Kind);
        Assert.Contains("ModelPath", ex.Message);
    }

    [Fact]
    public async Task MLNetNativeBridge_FailsOnNonexistentModelFile()
    {
        // The engine's CreateAsync checks File.Exists(modelPath) before
        // touching the OnnxScoringEstimator; we exercise that early-exit
        // path to avoid loading a real .onnx fixture.
        var bridge = (INativeBridge)Activator.CreateInstance(typeof(MLNetNativeBridge), nonPublic: true)!;
        var fakePath = Path.Combine(Path.GetTempPath(), $"dvai-test-mlnet-nonexistent-{Guid.NewGuid():N}.onnx");
        var ex = await Assert.ThrowsAsync<DVAIBridgeException>(() =>
            bridge.StartAsync(new StartOptions { Backend = BackendKind.MLNet, ModelPath = fakePath }, CancellationToken.None));
        Assert.Equal(DVAIBridgeErrorKind.ConfigurationInvalid, ex.Kind);
        Assert.Contains("ONNX model file not found", ex.Message);
    }

    [Fact]
    public async Task MLNetNativeBridge_StatusReportsNotRunningBeforeStart()
    {
        var bridge = (INativeBridge)Activator.CreateInstance(typeof(MLNetNativeBridge), nonPublic: true)!;
        var status = await bridge.GetStatusAsync(CancellationToken.None);
        Assert.False(status.Running);
        Assert.Null(status.BaseUrl);
        Assert.Null(status.Port);
        Assert.Null(status.Backend);
        Assert.Null(status.ModelId);
    }

    [Fact]
    public async Task MLNetNativeBridge_StopAsyncIsIdempotentBeforeStart()
    {
        // Verifies cleanup semantics: StopAsync on a never-started bridge
        // must be a no-op (no NRE, no thrown exception). This is the same
        // contract the iOS / Android / Desktop bridges honor.
        var bridge = (INativeBridge)Activator.CreateInstance(typeof(MLNetNativeBridge), nonPublic: true)!;
        await bridge.StopAsync(CancellationToken.None);
        // Calling twice should also be safe.
        await bridge.StopAsync(CancellationToken.None);
        var status = await bridge.GetStatusAsync(CancellationToken.None);
        Assert.False(status.Running);
    }

    [Fact]
    public async Task MLNetNativeBridge_DownloadModelReturnsConfigurationInvalid()
    {
        // The MLNet slice deliberately ships no built-in downloader (the
        // bridge code raises ConfigurationInvalid pointing consumers at
        // the desktop slice's downloader / HuggingFace CLI). We assert
        // that contract here so it doesn't drift.
        var bridge = (INativeBridge)Activator.CreateInstance(typeof(MLNetNativeBridge), nonPublic: true)!;
        var ex = await Assert.ThrowsAsync<DVAIBridgeException>(() =>
            bridge.DownloadModelAsync(new DownloadOptions(
                Url: "http://example.invalid/model.onnx",
                Sha256: "deadbeef"), CancellationToken.None));
        Assert.Equal(DVAIBridgeErrorKind.ConfigurationInvalid, ex.Kind);
        Assert.Contains("ML.NET backend doesn't ship a built-in downloader", ex.Message);
    }

    [Fact]
    public void BackendKind_MLNetRoundTripsWireString()
    {
        // Wire-format invariant for the new backend (mirrors the analogous
        // OnnxBridgeTests assertion). Catches accidental rename of the
        // ToWireString() / FromWireString() mapping in BackendKind.cs.
        Assert.Equal("mlnet", BackendKind.MLNet.ToWireString());
        Assert.Equal(BackendKind.MLNet, BackendKindExtensions.FromWireString("mlnet"));
    }

    [Fact]
    public async Task MLNetNativeBridge_SubscribeProgress_ReturnsDisposableThatRemoves()
    {
        // MLNet-specific edge case: SubscribeProgress must return a
        // disposable that actually unhooks the handler. If it didn't, an
        // app that re-subscribes per request would leak handlers and pump
        // duplicate events on every emission. Verify by emitting via the
        // (private) EmitProgress path through a known transition: a failed
        // start emits Start + Load before the model-load throws.
        var bridge = (INativeBridge)Activator.CreateInstance(typeof(MLNetNativeBridge), nonPublic: true)!;

        var seenA = 0;
        var seenB = 0;
        using (bridge.SubscribeProgress(_ => Interlocked.Increment(ref seenA)))
        {
            var subB = bridge.SubscribeProgress(_ => Interlocked.Increment(ref seenB));
            subB.Dispose();

            // Trigger an emission via a failing start (ModelPath invalid).
            await Assert.ThrowsAsync<DVAIBridgeException>(() =>
                bridge.StartAsync(
                    new StartOptions { Backend = BackendKind.MLNet, ModelPath = Path.Combine(Path.GetTempPath(), $"dvai-test-mlnet-{Guid.NewGuid():N}.onnx") },
                    CancellationToken.None));
        }

        Assert.True(seenA >= 1, "subscriber A should have observed at least the Start ProgressEvent");
        Assert.Equal(0, seenB);
    }
}
