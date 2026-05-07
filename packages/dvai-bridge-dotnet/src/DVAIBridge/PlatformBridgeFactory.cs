using System;
using System.Threading;
using System.Threading.Tasks;

namespace DVAIBridge;

/// <summary>
/// Resolves the per-platform <see cref="INativeBridge"/> at startup, keyed
/// by the requested <see cref="BackendKind"/> and the host operating system.
///
/// <para>
/// We can't take a hard <c>ProjectReference</c> on the iOS / Android /
/// Desktop / Onnx / MLNet slices from the bare-<c>net10.0</c> facade target —
/// that would force every consumer to drag in every binding DLL. Instead, we
/// use runtime type lookup: the platform-specific TFM slices (or the explicit
/// opt-in NuGets <c>DVAIBridge.OnnxRuntime</c> / <c>DVAIBridge.MLNet</c>)
/// load their assemblies into the AppDomain alongside the facade, and
/// <see cref="Type.GetType(string)"/> resolves the slice-internal class by
/// AQN.
/// </para>
///
/// <para>
/// Routing precedence per spec §3.8 / Task 24:
/// 1. <c>BackendKind.Onnx</c> + <c>DVAIBridge.OnnxRuntime</c> loaded → <c>OnnxNativeBridge</c> (any OS).
/// 2. <c>BackendKind.MLNet</c> + desktop OS + <c>DVAIBridge.MLNet</c> loaded → <c>MLNetNativeBridge</c>.
/// 3. iOS / Mac Catalyst + Llama-family backend → <c>IOSNativeBridge</c> via the
///    multi-target <c>DVAIBridge.iOS</c> NuGet (Task 14).
/// 4. Android + Llama-family backend → <c>AndroidNativeBridge</c>.
/// 5. Desktop OS (Windows / Linux / macOS-not-Catalyst) + Llama → <c>LlamaDesktopBridge</c>.
/// 6. Otherwise → <c>UnsupportedPlatformBridge</c> (clear <c>BackendUnavailable</c>).
/// </para>
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

    /// <summary>
    /// Per-OS overrides used by tests to simulate non-host platforms (e.g.
    /// asserting "on iOS, BackendKind.MediaPipe is rejected" from a Windows
    /// test runner). Production code never sets these — the
    /// <see cref="OperatingSystem"/> static checks are authoritative.
    /// </summary>
    [ThreadStatic]
    internal static SyntheticOs? SyntheticOsForTests;

    public static INativeBridge Create() => Create(BackendKind.Auto);

    /// <summary>
    /// Resolve the right <see cref="INativeBridge"/> for the given
    /// <see cref="BackendKind"/>. The factory's selection of a backend slice
    /// is keyed to the (OS, BackendKind) tuple.
    /// </summary>
    public static INativeBridge Create(BackendKind backend)
    {
        if (OverrideForTests is { } injected)
        {
            return injected;
        }

        var os = SyntheticOsForTests ?? DetectOs();

        // Step 1: ONNX is cross-platform — opt-in via the DVAIBridge.OnnxRuntime NuGet.
        if (backend == BackendKind.Onnx)
        {
            var bridge = TryCreate("DVAIBridge.OnnxRuntime.OnnxNativeBridge, DVAIBridge.OnnxRuntime");
            if (bridge is not null) return bridge;
            return new MissingPackageBridge(
                BackendKind.Onnx,
                "BackendKind.Onnx requires the DVAIBridge.OnnxRuntime NuGet — install it via `dotnet add package DVAIBridge.OnnxRuntime`.");
        }

        // Step 2: ML.NET is desktop-primary; reject on mobile early.
        if (backend == BackendKind.MLNet)
        {
            if (!IsDesktop(os))
            {
                return new MissingPackageBridge(
                    BackendKind.MLNet,
                    "BackendKind.MLNet is desktop-only (Windows / Linux / macOS / Catalyst). " +
                    "Use BackendKind.Onnx on iOS / Android instead.");
            }
            var bridge = TryCreate("DVAIBridge.MLNet.MLNetNativeBridge, DVAIBridge.MLNet");
            if (bridge is not null) return bridge;
            return new MissingPackageBridge(
                BackendKind.MLNet,
                "BackendKind.MLNet requires the DVAIBridge.MLNet NuGet — install it via `dotnet add package DVAIBridge.MLNet`.");
        }

        // Step 3: iOS / Catalyst — both routed via the multi-target DVAIBridge.iOS NuGet.
        if (os == OsKind.IOS || os == OsKind.MacCatalyst)
        {
            var t = Type.GetType("DVAIBridge.iOS.IOSNativeBridge, DVAIBridge.iOS");
            if (t is not null && Activator.CreateInstance(t) is INativeBridge bridge)
            {
                return bridge;
            }
            return new UnsupportedPlatformBridge();
        }

        // Step 4: Android.
        if (os == OsKind.Android)
        {
            var t = Type.GetType("DVAIBridge.Android.AndroidNativeBridge, DVAIBridge.Android");
            if (t is not null && Activator.CreateInstance(t) is INativeBridge bridge)
            {
                return bridge;
            }
            return new UnsupportedPlatformBridge();
        }

        // Step 5: Desktop (Windows / Linux / non-Catalyst macOS) → LlamaDesktopBridge.
        if (IsDesktop(os))
        {
            var t = Type.GetType("DVAIBridge.Desktop.LlamaDesktopBridge, DVAIBridge.Desktop");
            if (t is not null && Activator.CreateInstance(t) is INativeBridge bridge)
            {
                return bridge;
            }
            return new MissingPackageBridge(
                BackendKind.Llama,
                "Desktop Llama backend requires the DVAIBridge.Desktop NuGet — install it via `dotnet add package DVAIBridge.Desktop`.");
        }

        return new UnsupportedPlatformBridge();
    }

    private static INativeBridge? TryCreate(string assemblyQualifiedName)
    {
        var t = Type.GetType(assemblyQualifiedName);
        if (t is null) return null;
        return Activator.CreateInstance(t) as INativeBridge;
    }

    /// <summary>
    /// Test-only override for the discovery factory (Phase 3 Task 8e).
    /// Production code routes through <see cref="ResolveDiscoveryFactory"/>
    /// which probes the loaded slice assemblies via reflection.
    /// </summary>
    [ThreadStatic]
    internal static IDiscoveryFactory? OverrideDiscoveryForTests;

    /// <summary>
    /// Resolve the per-platform <see cref="IDiscoveryFactory"/>. Returns
    /// <c>null</c> when no slice has registered one (mobile bindings
    /// not yet shipped, desktop NuGet not loaded). The facade treats a
    /// <c>null</c> factory as "discovery disabled" — offload still
    /// works against <see cref="OffloadConfig.KnownPeers"/>.
    /// </summary>
    internal static IDiscoveryFactory? ResolveDiscoveryFactory()
    {
        if (OverrideDiscoveryForTests is { } injected) return injected;

        var os = SyntheticOsForTests ?? DetectOs();

        // Mobile: delegate to the native binding's factory if loaded.
        if (os == OsKind.IOS || os == OsKind.MacCatalyst)
        {
            return TryCreateDiscovery("DVAIBridge.iOS.Discovery.IOSDiscoveryFactory, DVAIBridge.iOS");
        }
        if (os == OsKind.Android)
        {
            return TryCreateDiscovery("DVAIBridge.Android.Discovery.AndroidDiscoveryFactory, DVAIBridge.Android");
        }

        // Desktop: Makaretu-backed factory in DVAIBridge.Desktop.
        if (IsDesktop(os))
        {
            return TryCreateDiscovery("DVAIBridge.Desktop.Discovery.MdnsDiscoveryFactory, DVAIBridge.Desktop");
        }

        return null;
    }

    private static IDiscoveryFactory? TryCreateDiscovery(string assemblyQualifiedName)
    {
        try
        {
            var t = Type.GetType(assemblyQualifiedName);
            if (t is null) return null;
            return Activator.CreateInstance(t) as IDiscoveryFactory;
        }
        catch
        {
            return null;
        }
    }

    internal enum OsKind { Unknown, IOS, MacCatalyst, Android, Windows, Linux, MacOS }

    /// <summary>
    /// Test-only synthetic OS marker — overrides the host
    /// <see cref="OperatingSystem"/> checks for cross-platform tests.
    /// </summary>
    internal sealed record SyntheticOs(OsKind Kind)
    {
        public static implicit operator OsKind(SyntheticOs s) => s.Kind;
    }

    private static OsKind DetectOs()
    {
        if (OperatingSystem.IsMacCatalyst()) return OsKind.MacCatalyst;
        if (OperatingSystem.IsIOS()) return OsKind.IOS;
        if (OperatingSystem.IsAndroid()) return OsKind.Android;
        if (OperatingSystem.IsWindows()) return OsKind.Windows;
        if (OperatingSystem.IsMacOS()) return OsKind.MacOS;
        if (OperatingSystem.IsLinux()) return OsKind.Linux;
        return OsKind.Unknown;
    }

    private static bool IsDesktop(OsKind os) =>
        os == OsKind.Windows || os == OsKind.Linux || os == OsKind.MacOS || os == OsKind.MacCatalyst;
}

/// <summary>
/// Stub <see cref="INativeBridge"/> used on platforms where DVAIBridge has
/// no native binding. Every method throws
/// <see cref="DVAIBridgeException.BackendUnavailable"/> with a clear "no
/// native binding for this platform" reason.
/// </summary>
internal sealed class UnsupportedPlatformBridge : INativeBridge
{
    private const string Reason =
        "DVAIBridge has no native binding loaded for the current platform. " +
        "Mobile (iOS / Android / Catalyst) and desktop (Windows / Linux / macOS) " +
        "are supported via the DVAIBridge.iOS / .Android / .Desktop NuGets — " +
        "ensure the appropriate slice is part of your project's restored graph.";

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

/// <summary>
/// Stub bridge returned when a consumer requested a backend whose opt-in
/// NuGet (<c>DVAIBridge.OnnxRuntime</c> / <c>DVAIBridge.MLNet</c> /
/// <c>DVAIBridge.Desktop</c>) isn't loaded. Every API call fails fast with
/// the install-hint message.
/// </summary>
internal sealed class MissingPackageBridge : INativeBridge
{
    private readonly BackendKind _backend;
    private readonly string _hint;

    public MissingPackageBridge(BackendKind backend, string hint)
    {
        _backend = backend;
        _hint = hint;
    }

    public Task<BoundServer> StartAsync(StartOptions opts, CancellationToken ct) =>
        Task.FromException<BoundServer>(DVAIBridgeException.BackendUnavailable(_backend, _hint));

    public Task StopAsync(CancellationToken ct) =>
        Task.FromException(DVAIBridgeException.BackendUnavailable(_backend, _hint));

    public Task<StatusInfo> GetStatusAsync(CancellationToken ct) =>
        Task.FromResult(new StatusInfo(false, null, null, null, null));

    public Task<DownloadResult> DownloadModelAsync(DownloadOptions opts, CancellationToken ct) =>
        Task.FromException<DownloadResult>(DVAIBridgeException.BackendUnavailable(_backend, _hint));

    public IDisposable SubscribeProgress(Action<ProgressEvent> handler) => new NoopSubscription();

    private sealed class NoopSubscription : IDisposable
    {
        public void Dispose() { }
    }
}
