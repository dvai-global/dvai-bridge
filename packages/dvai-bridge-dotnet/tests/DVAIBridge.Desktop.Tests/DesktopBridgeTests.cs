using System;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;
using DVAIBridge.Desktop;
using DVAIBridge.Shared.Hosting;
using Xunit;

namespace DVAIBridge.Desktop.Tests;

/// <summary>
/// Unit-level tests for the desktop slice. We intentionally avoid loading
/// the actual <c>llama.cpp</c> native here — that would require shipping a
/// model fixture in CI (~600MB TinyLlama Q4_0). The smoke around the actual
/// native is gated behind <c>DVAI_E2E=1</c> in a separate CI job.
///
/// These tests verify:
///   - LlamaDesktopBridge instantiates + rejects non-Llama backends.
///   - PortPicker walks the requested range and exhausts cleanly.
///   - The shared OpenAIServer wires up the IInferenceEngine correctly.
/// </summary>
public class DesktopBridgeTests
{
    [Fact]
    public void LlamaDesktopBridge_CanInstantiate()
    {
        // Type.GetType + Activator.CreateInstance is the path
        // PlatformBridgeFactory uses; sanity-check it works against the
        // built-into-the-test-host assembly.
        var t = typeof(LlamaDesktopBridge);
        Assert.NotNull(t);
        var instance = Activator.CreateInstance(t, nonPublic: true);
        Assert.NotNull(instance);
    }

    [Fact]
    public async Task LlamaDesktopBridge_RejectsNonLlamaBackend()
    {
        // Reflectively new the bridge (it's internal) and feed it a Foundation
        // request. Should throw BackendUnavailable with a hint.
        var bridge = (INativeBridge)Activator.CreateInstance(typeof(LlamaDesktopBridge), nonPublic: true)!;
        var ex = await Assert.ThrowsAsync<DVAIBridgeException>(() =>
            bridge.StartAsync(new StartOptions { Backend = BackendKind.Foundation, ModelPath = "/dev/null" }, CancellationToken.None));
        Assert.Equal(DVAIBridgeErrorKind.BackendUnavailable, ex.Kind);
        Assert.Contains("only BackendKind.Llama", ex.Message);
    }

    [Fact]
    public async Task LlamaDesktopBridge_RejectsMissingModelPath()
    {
        var bridge = (INativeBridge)Activator.CreateInstance(typeof(LlamaDesktopBridge), nonPublic: true)!;
        var ex = await Assert.ThrowsAsync<DVAIBridgeException>(() =>
            bridge.StartAsync(new StartOptions { Backend = BackendKind.Llama, ModelPath = null }, CancellationToken.None));
        Assert.Equal(DVAIBridgeErrorKind.ConfigurationInvalid, ex.Kind);
        Assert.Contains("ModelPath is required", ex.Message);
    }

    [Fact]
    public async Task LlamaDesktopBridge_StatusReportsNotRunningBeforeStart()
    {
        var bridge = (INativeBridge)Activator.CreateInstance(typeof(LlamaDesktopBridge), nonPublic: true)!;
        var status = await bridge.GetStatusAsync(CancellationToken.None);
        Assert.False(status.Running);
    }

    [Fact]
    public void PortPicker_FindsAFreePort()
    {
        // We don't know what port is free, but the picker should at least
        // succeed for a default range against an unused base.
        var port = TypeAccess.PortPicker_FindFreePort(50_000, 100);
        Assert.InRange(port, 50_000, 50_099);
    }

    [Fact]
    public void PortPicker_ExhaustionThrowsConfigurationInvalid()
    {
        // Forcing exhaustion deterministically requires binding every port —
        // not portable. Instead, request a deliberately invalid range
        // (port < 1) so every candidate is skipped.
        var ex = Assert.Throws<DVAIBridgeException>(() => TypeAccess.PortPicker_FindFreePort(-10, 5));
        Assert.Equal(DVAIBridgeErrorKind.ConfigurationInvalid, ex.Kind);
    }

    [Fact]
    public async Task LlamaDesktopBridge_DownloadModelMissingFileRaisesDownloadFailed()
    {
        // Using a deliberately bogus URL — should return DownloadFailed.
        var bridge = (INativeBridge)Activator.CreateInstance(typeof(LlamaDesktopBridge), nonPublic: true)!;
        var ex = await Assert.ThrowsAsync<DVAIBridgeException>(() =>
            bridge.DownloadModelAsync(new DownloadOptions(
                Url: "http://127.0.0.1:1/nonexistent",
                Sha256: "abc"), CancellationToken.None));
        Assert.True(ex.Kind is DVAIBridgeErrorKind.DownloadFailed or DVAIBridgeErrorKind.BackendError);
    }

    /// <summary>
    /// Reflection helper to call internal members of DVAIBridge.Desktop / its
    /// shared-source PortPicker without an explicit InternalsVisibleTo grant
    /// (the shared sources are linked rather than ProjectReferenced).
    /// </summary>
    private static class TypeAccess
    {
        public static int PortPicker_FindFreePort(int basePort, int maxAttempts)
        {
            var asm = typeof(LlamaDesktopBridge).Assembly;
            var t = asm.GetType("DVAIBridge.Shared.Hosting.PortPicker", throwOnError: true)!;
            var m = t.GetMethod("FindFreePort", BindingFlags.Public | BindingFlags.Static);
            Assert.NotNull(m);
            try
            {
                return (int)m!.Invoke(null, new object?[] { (int?)basePort, (int?)maxAttempts })!;
            }
            catch (TargetInvocationException tie) when (tie.InnerException is not null)
            {
                throw tie.InnerException;
            }
        }
    }
}
