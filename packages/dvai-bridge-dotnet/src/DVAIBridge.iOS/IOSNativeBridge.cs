using System;
using System.Threading;
using System.Threading.Tasks;
using DVAIBridge.iOS.Native;
using Foundation;

[assembly: System.Runtime.CompilerServices.InternalsVisibleTo("DVAIBridge.Tests")]

namespace DVAIBridge.iOS;

/// <summary>
/// iOS-side implementation of <see cref="INativeBridge"/>. Marshals C#
/// records to <see cref="NSDictionary"/>, calls the bound Obj-C wrapper,
/// then marshals responses back. Maps <see cref="NSErrorException"/> to
/// <see cref="DVAIBridgeException"/> via the wire-format <c>kind</c> key.
/// </summary>
/// <remarks>
/// Resolved at runtime by <c>PlatformBridgeFactory.Create()</c> via
/// <c>Type.GetType("DVAIBridge.iOS.IOSNativeBridge, DVAIBridge.iOS")</c>.
/// The class is internal to the assembly but instantiable through
/// reflection (parameterless constructor).
/// </remarks>
internal sealed class IOSNativeBridge : INativeBridge
{
    public IOSNativeBridge() { }

    public async Task<BoundServer> StartAsync(StartOptions opts, CancellationToken ct)
    {
        var dict = StartOptionsToDictionary(opts);
        try
        {
            var resp = await DVAIBridgeNetBridge.Shared.StartAsync(dict).ConfigureAwait(false);
            return ResponseToBoundServer(resp);
        }
        catch (NSErrorException e)
        {
            throw MapNSError(e.Error);
        }
    }

    public async Task StopAsync(CancellationToken ct)
    {
        try
        {
            await DVAIBridgeNetBridge.Shared.StopAsync().ConfigureAwait(false);
        }
        catch (NSErrorException e)
        {
            throw MapNSError(e.Error);
        }
    }

    public async Task<StatusInfo> GetStatusAsync(CancellationToken ct)
    {
        try
        {
            var resp = await DVAIBridgeNetBridge.Shared.StatusAsync().ConfigureAwait(false);
            return ResponseToStatusInfo(resp);
        }
        catch (NSErrorException e)
        {
            throw MapNSError(e.Error);
        }
    }

    public async Task<DownloadResult> DownloadModelAsync(DownloadOptions opts, CancellationToken ct)
    {
        var dict = DownloadOptionsToDictionary(opts);
        try
        {
            var resp = await DVAIBridgeNetBridge.Shared.DownloadModelAsync(dict).ConfigureAwait(false);
            return ResponseToDownloadResult(resp);
        }
        catch (NSErrorException e)
        {
            throw MapNSError(e.Error);
        }
    }

    public IDisposable SubscribeProgress(Action<ProgressEvent> handler)
    {
        var cancellable = DVAIBridgeNetBridge.Shared.SubscribeProgress(d =>
        {
            handler(ResponseToProgressEvent(d));
        });
        return new CancellableDisposable(cancellable);
    }

    // ------------------------------------------------------------------
    // Marshalling: C# records → NSDictionary
    // ------------------------------------------------------------------

    private static NSDictionary StartOptionsToDictionary(StartOptions opts)
    {
        var d = new NSMutableDictionary
        {
            ["backend"] = (NSString)opts.Backend.ToWireString(),
        };
        if (opts.ModelPath is { } v1) d["modelPath"] = (NSString)v1;
        if (opts.TokenizerPath is { } v2) d["tokenizerPath"] = (NSString)v2;
        if (opts.MmprojPath is { } v3) d["mmprojPath"] = (NSString)v3;
        if (opts.ChatTemplate is { } v4) d["chatTemplate"] = (NSString)v4;
        if (opts.ModelId is { } v5) d["modelId"] = (NSString)v5;
        if (opts.ContextSize is { } v6) d["contextSize"] = NSNumber.FromInt32(v6);
        if (opts.Threads is { } v7) d["threads"] = NSNumber.FromInt32(v7);
        if (opts.GpuLayers is { } v8) d["gpuLayers"] = NSNumber.FromInt32(v8);
        if (opts.HttpBasePort is { } v9) d["httpBasePort"] = NSNumber.FromInt32(v9);
        if (opts.HttpMaxPortAttempts is { } v10) d["httpMaxPortAttempts"] = NSNumber.FromInt32(v10);
        if (opts.CorsOrigin is { } v11) d["corsOrigin"] = (NSString)v11;
        if (opts.Temperature is { } v12) d["temperature"] = NSNumber.FromDouble(v12);
        if (opts.TopP is { } v13) d["topP"] = NSNumber.FromDouble(v13);
        if (opts.TopK is { } v14) d["topK"] = NSNumber.FromInt32(v14);
        if (opts.MaxNewTokens is { } v15) d["maxNewTokens"] = NSNumber.FromInt32(v15);
        d["embeddingMode"] = NSNumber.FromBoolean(opts.EmbeddingMode);
        d["visionEnabled"] = NSNumber.FromBoolean(opts.VisionEnabled);
        return d;
    }

    private static NSDictionary DownloadOptionsToDictionary(DownloadOptions opts)
    {
        var d = new NSMutableDictionary
        {
            ["url"] = (NSString)opts.Url,
            ["sha256"] = (NSString)opts.Sha256,
        };
        if (opts.DestFilename is { } dest)
        {
            d["destFilename"] = (NSString)dest;
        }
        return d;
    }

    // ------------------------------------------------------------------
    // Marshalling: NSDictionary → C# records
    // ------------------------------------------------------------------

    private static BoundServer ResponseToBoundServer(NSDictionary d)
    {
        var baseUrl = GetString(d, "baseUrl") ?? throw new InvalidOperationException("missing baseUrl in BoundServer");
        var port = GetInt(d, "port") ?? 0;
        var backendStr = GetString(d, "backend") ?? "auto";
        var modelId = GetString(d, "modelId") ?? string.Empty;
        return new BoundServer(baseUrl, port, BackendKindExtensions.FromWireString(backendStr), modelId);
    }

    private static StatusInfo ResponseToStatusInfo(NSDictionary d)
    {
        var running = GetBool(d, "running") ?? false;
        var baseUrl = GetString(d, "baseUrl");
        var port = GetInt(d, "port");
        var backendStr = GetString(d, "backend");
        var modelId = GetString(d, "modelId");
        BackendKind? backend = backendStr is null ? null : BackendKindExtensions.FromWireString(backendStr);
        return new StatusInfo(running, baseUrl, port, backend, modelId);
    }

    private static DownloadResult ResponseToDownloadResult(NSDictionary d)
    {
        var path = GetString(d, "path") ?? throw new InvalidOperationException("missing path in DownloadResult");
        var sha256 = GetString(d, "sha256") ?? string.Empty;
        var size = GetLong(d, "sizeBytes") ?? 0L;
        return new DownloadResult(path, sha256, size);
    }

    private static ProgressEvent ResponseToProgressEvent(NSDictionary d)
    {
        var kindStr = GetString(d, "kind") ?? "progress";
        var phaseStr = GetString(d, "phase") ?? "load";
        var percent = GetDouble(d, "percent");
        var message = GetString(d, "message");
        var errorKind = GetString(d, "errorKind");
        var errorMessage = GetString(d, "errorMessage");
        return new ProgressEvent(
            ParseProgressKind(kindStr),
            ParseProgressPhase(phaseStr),
            percent,
            message,
            errorKind,
            errorMessage);
    }

    private static ProgressKind ParseProgressKind(string s) => s switch
    {
        "started" => ProgressKind.Started,
        "progress" => ProgressKind.Progress,
        "completed" => ProgressKind.Completed,
        "failed" => ProgressKind.Failed,
        _ => ProgressKind.Progress,
    };

    private static ProgressPhase ParseProgressPhase(string s) => s switch
    {
        "start" => ProgressPhase.Start,
        "stop" => ProgressPhase.Stop,
        "download" => ProgressPhase.Download,
        "load" => ProgressPhase.Load,
        "ready" => ProgressPhase.Ready,
        "verify" => ProgressPhase.Verify,
        "error" => ProgressPhase.Error,
        _ => ProgressPhase.Load,
    };

    // ------------------------------------------------------------------
    // NSDictionary scalar accessors (defensive; the wrapper produces
    // well-formed dictionaries but consumers can be defensive).
    // ------------------------------------------------------------------

    private static string? GetString(NSDictionary? d, string key)
    {
        if (d is null) return null;
        if (d.TryGetValue((NSString)key, out var obj) && obj is NSString s)
        {
            return (string)s;
        }
        return null;
    }

    private static int? GetInt(NSDictionary d, string key)
    {
        if (d.TryGetValue((NSString)key, out var obj) && obj is NSNumber n)
        {
            return n.Int32Value;
        }
        return null;
    }

    private static long? GetLong(NSDictionary d, string key)
    {
        if (d.TryGetValue((NSString)key, out var obj) && obj is NSNumber n)
        {
            return n.Int64Value;
        }
        return null;
    }

    private static double? GetDouble(NSDictionary d, string key)
    {
        if (d.TryGetValue((NSString)key, out var obj) && obj is NSNumber n)
        {
            return n.DoubleValue;
        }
        return null;
    }

    private static bool? GetBool(NSDictionary d, string key)
    {
        if (d.TryGetValue((NSString)key, out var obj) && obj is NSNumber n)
        {
            return n.BoolValue;
        }
        return null;
    }

    // ------------------------------------------------------------------
    // NSError → DVAIBridgeException mapping
    // ------------------------------------------------------------------

    private static DVAIBridgeException MapNSError(NSError err)
    {
        var kindStr = (err.UserInfo[(NSString)"kind"] as NSString)?.ToString() ?? "backend_error";
        var details = err.UserInfo[(NSString)"details"] as NSDictionary;
        var msg = err.LocalizedDescription;

        return kindStr switch
        {
            "already_started" => DVAIBridgeException.AlreadyStarted(
                ParseBackend(details, BackendKind.Auto),
                GetString(details, "baseUrl") ?? string.Empty),
            "configuration_invalid" => DVAIBridgeException.ConfigurationInvalid(
                GetString(details, "reason") ?? msg),
            "model_load_failed" => DVAIBridgeException.ModelLoadFailed(
                GetString(details, "reason") ?? msg),
            "backend_unavailable" => DVAIBridgeException.BackendUnavailable(
                ParseBackend(details, BackendKind.Auto),
                GetString(details, "reason") ?? msg),
            "checksum_mismatch" => DVAIBridgeException.ChecksumMismatch(
                GetString(details, "expected") ?? string.Empty,
                GetString(details, "got") ?? string.Empty),
            "download_failed" => DVAIBridgeException.DownloadFailed(
                GetString(details, "reason") ?? msg),
            _ => DVAIBridgeException.BackendError(msg),
        };
    }

    private static BackendKind ParseBackend(NSDictionary? details, BackendKind fallback)
    {
        var backendStr = GetString(details, "backend");
        if (backendStr is null)
        {
            return fallback;
        }
        try
        {
            return BackendKindExtensions.FromWireString(backendStr);
        }
        catch (ArgumentException)
        {
            return fallback;
        }
    }

    private sealed class CancellableDisposable : IDisposable
    {
        private DVAIBridgeNetCancellable? _cancellable;

        public CancellableDisposable(DVAIBridgeNetCancellable cancellable)
        {
            _cancellable = cancellable;
        }

        public void Dispose()
        {
            _cancellable?.Cancel();
            _cancellable?.Dispose();
            _cancellable = null;
        }
    }
}
