using System;
using System.Threading;
using System.Threading.Tasks;

namespace DVAIBridge;

/// <summary>
/// Internal contract bridging the public C# facade (this assembly) to the
/// per-platform binding implementations
/// (<c>DVAIBridge.iOS.IOSNativeBridge</c> on iOS,
/// <c>DVAIBridge.Android.AndroidNativeBridge</c> on Android,
/// <c>UnsupportedPlatformBridge</c> elsewhere).
/// </summary>
/// <remarks>
/// Visible to the platform-slice assemblies via <c>InternalsVisibleTo</c>
/// in <c>AssemblyInfo.cs</c>. Test-only fakes live in <c>DVAIBridge.Tests</c>
/// (which has the matching <c>InternalsVisibleTo</c> grant).
/// </remarks>
internal interface INativeBridge
{
    /// <summary>Start the embedded HTTP server with the given options.</summary>
    Task<BoundServer> StartAsync(StartOptions opts, CancellationToken ct);

    /// <summary>Stop the embedded HTTP server. Idempotent.</summary>
    Task StopAsync(CancellationToken ct);

    /// <summary>Snapshot of the current bridge state.</summary>
    Task<StatusInfo> GetStatusAsync(CancellationToken ct);

    /// <summary>Download a model file with sha256 verification.</summary>
    Task<DownloadResult> DownloadModelAsync(DownloadOptions opts, CancellationToken ct);

    /// <summary>
    /// Subscribe to push-style progress events. The returned
    /// <see cref="IDisposable"/> unregisters the handler on dispose.
    /// </summary>
    IDisposable SubscribeProgress(Action<ProgressEvent> handler);
}
