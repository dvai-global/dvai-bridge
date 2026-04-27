using System;
using System.Threading;
using System.Threading.Tasks;

namespace DVAIBridge;

/// <summary>
/// Resolves the per-platform <see cref="INativeBridge"/> at startup.
///
/// We can't take a hard <c>ProjectReference</c> on the iOS / Android slices
/// from the bare-<c>net10.0</c> facade target — that would force every WinUI
/// / Avalonia / Blazor consumer to drag in iOS or Android binding DLLs.
/// Instead, we use runtime type lookup: the facade's iOS-flavoured + Android-
/// flavoured TFM slices include <c>ProjectReference</c>s on the binding
/// projects, so on those TFMs the binding assemblies are loaded into the
/// app's AppDomain by the platform host. <see cref="Type.GetType(string)"/>
/// then resolves the slice-internal class by AQN.
/// </summary>
internal static class PlatformBridgeFactory
{
    /// <summary>
    /// Test-only override. Set this from <c>DVAIBridge.Tests</c> via the
    /// <c>InternalsVisibleTo</c> grant to inject a fake bridge for the
    /// <see cref="DVAIBridge.Shared"/> singleton path. Note: tests that
    /// want isolation from the singleton should instead construct
    /// <c>new DVAIBridge(IFakeNativeBridge)</c> directly via the
    /// internal test-seam constructor.
    /// </summary>
    [ThreadStatic]
    internal static INativeBridge? OverrideForTests;

    public static INativeBridge Create()
    {
        if (OverrideForTests is { } injected)
        {
            return injected;
        }

        if (OperatingSystem.IsIOS())
        {
            // The iOS binding slice (DVAIBridge.iOS) registers this type at
            // build time. AQN must match the <AssemblyName> + namespace used
            // by IOSNativeBridge.cs.
            var t = Type.GetType("DVAIBridge.iOS.IOSNativeBridge, DVAIBridge.iOS");
            if (t is not null && Activator.CreateInstance(t) is INativeBridge bridge)
            {
                return bridge;
            }
            // Slice not loaded — fall through to the unsupported stub so the
            // runtime error is a clear BackendUnavailable rather than a
            // missing-type NullReferenceException.
        }
        else if (OperatingSystem.IsAndroid())
        {
            var t = Type.GetType("DVAIBridge.Android.AndroidNativeBridge, DVAIBridge.Android");
            if (t is not null && Activator.CreateInstance(t) is INativeBridge bridge)
            {
                return bridge;
            }
        }

        return new UnsupportedPlatformBridge();
    }
}

/// <summary>
/// Stub <see cref="INativeBridge"/> used on platforms where DVAIBridge has
/// no native binding (Windows / Linux / macOS / browser TFMs in v2.4).
/// Every method throws
/// <see cref="DVAIBridgeException.BackendUnavailable"/> with a clear "no
/// native binding for this platform" reason.
/// </summary>
internal sealed class UnsupportedPlatformBridge : INativeBridge
{
    private const string Reason =
        "DVAIBridge native bindings only ship for iOS and Android in v2.4. " +
        "WinUI 3 / Avalonia / desktop / Blazor consumers can install the package " +
        "(the facade compiles cleanly) but every API call fails fast with this exception.";

    public Task<BoundServer> StartAsync(StartOptions opts, CancellationToken ct) =>
        Task.FromException<BoundServer>(DVAIBridgeException.BackendUnavailable(opts.Backend, Reason));

    public Task StopAsync(CancellationToken ct) =>
        Task.FromException(DVAIBridgeException.BackendUnavailable(BackendKind.Auto, Reason));

    public Task<StatusInfo> GetStatusAsync(CancellationToken ct) =>
        Task.FromResult(new StatusInfo(false, null, null, null, null));

    public Task<DownloadResult> DownloadModelAsync(DownloadOptions opts, CancellationToken ct) =>
        Task.FromException<DownloadResult>(DVAIBridgeException.BackendUnavailable(BackendKind.Auto, Reason));

    public IDisposable SubscribeProgress(Action<ProgressEvent> handler) => new NoopSubscription();

    private sealed class NoopSubscription : IDisposable
    {
        public void Dispose() { }
    }
}
