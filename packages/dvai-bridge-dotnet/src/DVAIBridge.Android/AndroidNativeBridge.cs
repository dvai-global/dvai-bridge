// =============================================================================
// AndroidNativeBridge.cs
//
// Maps the public DVAIBridge facade onto the .NET 10 Android binding of the
// `co.deepvoiceai:dvai-bridge` AAR. The binding generator (class-parse +
// XAJavaInterop1) emits C# wrappers under the namespace `CO.Deepvoiceai.Bridge.*`
// — see `Transforms/Metadata.xml` for the rename of the Kotlin object
// `co.deepvoiceai.bridge.DVAIBridge` to `NativeDVAIBridge` (avoids colliding
// with our managed facade's `DVAIBridge` type) and a handful of other transforms.
//
// Suspend functions
// -----------------
// The Kotlin object `DVAIBridge` exposes three `suspend` methods that we
// need: `start(opts)`, `stop()`, `downloadModel(opts)`. The JVM signature
// for a suspend function appends a trailing `Continuation` parameter and
// returns `Object` (either the result or the `COROUTINE_SUSPENDED` sentinel).
//
// Microsoft's .NET 10 binding generator binds these as
// `Start(opts, IContinuation _completion)` etc. — no automatic Task<T>
// wrapping (which would require kotlin_metadata-aware codegen we don't
// have yet). We bridge it manually via <see cref="TaskContinuation{T}"/>,
// a `Java.Lang.Object` subclass that implements `kotlin.coroutines.Continuation`
// and flips a `TaskCompletionSource<T>` from inside `resumeWith()`.
//
// Result unwrapping
// -----------------
// Kotlin's `Result<T>` is a `@JvmInline value class` — at the JVM level
// it's just `Object`. A success carries the raw value (or the
// `Result.Companion.success` sentinel for null); a failure is a
// `Result.Failure` wrapper holding the `Throwable`. We inspect the type
// via reflection in <see cref="TaskContinuation{T}.UnwrapResult"/>.
//
// Required reference jars (see DVAIBridge.Android.csproj):
//   - native/android-shared-core-$(Version).aar         (CorsConfig, OffloadConfig)
//   - native/kotlin-coroutines-min.jar                  (Continuation, EmptyCoroutineContext, Result)
// These are class-parse-only references (Bind=false) — the runtime types
// come from the consumer app's transitive Maven Central dep graph (the
// `co.deepvoiceai:dvai-bridge:4.0.0` POM already pulls them in).
// =============================================================================

using System;
using System.Threading;
using System.Threading.Tasks;
using Android.Runtime;
using Java.Interop;

[assembly: System.Runtime.CompilerServices.InternalsVisibleTo("DVAIBridge.Tests")]

namespace DVAIBridge.Android;

#if BINDINGS_GENERATED

// Aliases for the binding-generator-emitted types. Keeps the call sites
// readable without dragging every CO.Deepvoiceai.Bridge.* into the file's
// using list (the namespace would otherwise collide with our facade's
// own `DVAIBridge` type via implicit-using resolution).
using NativeBridge = global::CO.Deepvoiceai.Bridge.NativeDVAIBridge;
using NativeStartOptions = global::CO.Deepvoiceai.Bridge.StartOptions;
using NativeBoundServer = global::CO.Deepvoiceai.Bridge.BoundServer;
using NativeStatusInfo = global::CO.Deepvoiceai.Bridge.StatusInfo;
using NativeDownloadOptions = global::CO.Deepvoiceai.Bridge.DownloadOptions;
using NativeDownloadResult = global::CO.Deepvoiceai.Bridge.DownloadResult;
using NativeBackendKind = global::CO.Deepvoiceai.Bridge.BackendKind;
using NativeError = global::CO.Deepvoiceai.Bridge.DVAIBridgeError;
using NativeProgressEvent = global::CO.Deepvoiceai.Bridge.ProgressEvent;
using NativeProgressListener = global::CO.Deepvoiceai.Bridge.IProgressListener;
using NativeContinuation = global::Kotlin.Coroutines.IContinuation;
using NativeCoroutineContext = global::Kotlin.Coroutines.ICoroutineContext;
using NativeEmptyContext = global::Kotlin.Coroutines.EmptyCoroutineContext;

/// <summary>
/// Android-side implementation of <see cref="INativeBridge"/>. Calls the
/// generated Java/Kotlin bindings emitted from the
/// <c>co.deepvoiceai:dvai-bridge:$(Version)</c> AAR.
/// </summary>
/// <remarks>
/// Resolved at runtime by <c>PlatformBridgeFactory.Create()</c> via
/// <c>Type.GetType("DVAIBridge.Android.AndroidNativeBridge, DVAIBridge.Android")</c>.
/// </remarks>
internal sealed class AndroidNativeBridge : INativeBridge
{
    public AndroidNativeBridge()
    {
        // The Phase 3D AAR's `DVAIBridge.init(applicationContext)` MUST be
        // called once from the consumer app's `Application.onCreate()`.
        // The .NET facade can't know the application's Context (no MAUI/Avalonia
        // dependency); we trust the consumer's MAUI startup hooks
        // (e.g. `MauiAppBuilder.UseMauiApp<App>().ConfigureLifecycleEvents`)
        // to wire `DVAIBridge.Android.Bootstrap.Init(context)` per the
        // documented quickstart in `docs/guide/dotnet-sdk.md`.
    }

    public Task<BoundServer> StartAsync(StartOptions opts, CancellationToken ct)
    {
        try
        {
            var nativeOpts = StartOptionsToNative(opts);
            var tcs = new TaskCompletionSource<NativeBoundServer?>(TaskCreationOptions.RunContinuationsAsynchronously);
            ct.Register(() => tcs.TrySetCanceled(ct));
            var cont = new TaskContinuation<NativeBoundServer?>(tcs);
            // Suspend may complete synchronously (returns the actual result
            // instead of COROUTINE_SUSPENDED). Capture either form.
            var sync = NativeBridge.Instance.Start(nativeOpts, cont);
            if (sync is not null && !IsCoroutineSuspended(sync))
            {
                tcs.TrySetResult(sync as NativeBoundServer);
            }
            return WrapAsync(tcs.Task, NativeBoundServerToManaged);
        }
        catch (Java.Lang.Throwable e)
        {
            return Task.FromException<BoundServer>(MapJavaThrowable(e));
        }
    }

    public Task StopAsync(CancellationToken ct)
    {
        try
        {
            var tcs = new TaskCompletionSource<Java.Lang.Object?>(TaskCreationOptions.RunContinuationsAsynchronously);
            ct.Register(() => tcs.TrySetCanceled(ct));
            var cont = new TaskContinuation<Java.Lang.Object?>(tcs);
            var sync = NativeBridge.Instance.Stop(cont);
            if (sync is not null && !IsCoroutineSuspended(sync))
            {
                tcs.TrySetResult(null);
            }
            return tcs.Task;
        }
        catch (Java.Lang.Throwable e)
        {
            return Task.FromException(MapJavaThrowable(e));
        }
    }

    public Task<StatusInfo> GetStatusAsync(CancellationToken ct)
    {
        try
        {
            // status() is a synchronous (non-suspend) Kotlin function; bound
            // as a plain static C# method by the binding generator.
            var native = NativeBridge.Status();
            return Task.FromResult(NativeStatusInfoToManaged(native));
        }
        catch (Java.Lang.Throwable e)
        {
            return Task.FromException<StatusInfo>(MapJavaThrowable(e));
        }
    }

    public Task<DownloadResult> DownloadModelAsync(DownloadOptions opts, CancellationToken ct)
    {
        try
        {
            var nativeOpts = new NativeDownloadOptions(
                opts.Url,
                opts.Sha256,
                opts.DestFilename ?? string.Empty);
            var tcs = new TaskCompletionSource<NativeDownloadResult?>(TaskCreationOptions.RunContinuationsAsynchronously);
            ct.Register(() => tcs.TrySetCanceled(ct));
            var cont = new TaskContinuation<NativeDownloadResult?>(tcs);
            var sync = NativeBridge.Instance.DownloadModel(nativeOpts, cont);
            if (sync is not null && !IsCoroutineSuspended(sync))
            {
                tcs.TrySetResult(sync as NativeDownloadResult);
            }
            return WrapAsync(tcs.Task, NativeDownloadResultToManaged);
        }
        catch (Java.Lang.Throwable e)
        {
            return Task.FromException<DownloadResult>(MapJavaThrowable(e));
        }
    }

    public IDisposable SubscribeProgress(Action<ProgressEvent> handler)
    {
        // The Phase 3D AAR exposes both:
        //   - progressFlow : SharedFlow<ProgressEvent>      (Kotlin idiomatic)
        //   - addProgressListener / removeProgressListener (Java-friendly)
        // We use the Java-friendly listener path because the bound IFlow
        // wrapper is awkward in C# (the binding generator emits a clunky
        // shape for SharedFlow<T>; see plan Risk #5).
        var listener = new ProgressListenerAdapter(handler);
        NativeBridge.AddProgressListener(listener);
        return new ListenerDisposable(listener);
    }

    // ------------------------------------------------------------------
    // Marshalling helpers.
    // ------------------------------------------------------------------

    private static async Task<TOut> WrapAsync<TIn, TOut>(Task<TIn?> source, Func<TIn, TOut> map)
        where TIn : class
    {
        var inner = await source.ConfigureAwait(false);
        return map(inner!);
    }

    /// <summary>
    /// Bridges the public managed <see cref="StartOptions"/> record to the
    /// 22-arg Kotlin data-class constructor. We pass <c>null</c> for the
    /// optional fields the public C# surface doesn't expose yet
    /// (CorsConfig, OffloadConfig, etc.). The AAR's Kotlin defaults
    /// are honoured.
    /// </summary>
    private static NativeStartOptions StartOptionsToNative(StartOptions opts)
    {
        // Kotlin data-class constructor parameter order — keep in lockstep
        // with `StartOptions.kt` in the AAR source.
        return new NativeStartOptions(
            backend: ParseNativeBackend(opts.Backend),
            modelPath: opts.ModelPath ?? string.Empty,
            tokenizerPath: opts.TokenizerPath ?? string.Empty,
            mmprojPath: opts.MmprojPath ?? string.Empty,
            chatTemplate: opts.ChatTemplate ?? string.Empty,
            gpuLayers: opts.GpuLayers ?? 0,
            contextSize: opts.ContextSize ?? 0,
            threads: opts.Threads ?? 0,
            embeddingMode: opts.EmbeddingMode,
            visionEnabled: opts.VisionEnabled,
            temperature: (float)(opts.Temperature ?? 0.0),
            topP: (float)(opts.TopP ?? 0.0),
            topK: opts.TopK ?? 0,
            maxNewTokens: opts.MaxNewTokens ?? 0,
            httpBasePort: opts.HttpBasePort ?? 0,
            httpMaxPortAttempts: opts.HttpMaxPortAttempts ?? 0,
            corsOrigin: null!,                       // Kotlin default kicks in (Wildcard).
            modelId: opts.ModelId ?? string.Empty,
            offload: null!,                          // Kotlin default kicks in (disabled).
            licenseKeyPath: opts.LicenseKeyPath ?? string.Empty,
            licenseToken: opts.LicenseToken ?? string.Empty,
            hostBuildConfigDebug: (Java.Lang.Boolean?)null);
    }

    private static BoundServer NativeBoundServerToManaged(NativeBoundServer native) =>
        new(
            BaseUrl: native.BaseUrl,
            Port: native.Port,
            Backend: ParseManagedBackend(native.Backend),
            ModelId: native.ModelId);

    private static StatusInfo NativeStatusInfoToManaged(NativeStatusInfo native)
    {
        // The Kotlin StatusInfo doesn't expose a Port getter — extract from
        // BaseUrl ("http://127.0.0.1:38883/v1" -> 38883). When BaseUrl is
        // null (stopped), Port is null too.
        int? port = null;
        if (native.BaseUrl is { } url && Uri.TryCreate(url, UriKind.Absolute, out var parsed))
        {
            port = parsed.Port;
        }
        return new StatusInfo(
            Running: native.Running,
            BaseUrl: native.BaseUrl,
            Port: port,
            Backend: native.Backend is null ? null : ParseManagedBackend(native.Backend),
            ModelId: native.ModelId);
    }

    private static DownloadResult NativeDownloadResultToManaged(NativeDownloadResult native) =>
        new(
            Path: native.Path,
            Sha256: native.Sha256,
            SizeBytes: native.SizeBytes);

    private static NativeBackendKind ParseNativeBackend(BackendKind k) => k switch
    {
        BackendKind.Auto => NativeBackendKind.Auto!,
        BackendKind.Llama => NativeBackendKind.Llama!,
        BackendKind.MediaPipe => NativeBackendKind.MediaPipe!,
        BackendKind.LiteRT => NativeBackendKind.LiteRT!,
        // iOS-only backends raised earlier in the facade — defense in depth.
        _ => throw DVAIBridgeException.BackendUnavailable(k, $"{k} is iOS-only and not supported on Android."),
    };

    private static BackendKind ParseManagedBackend(NativeBackendKind k)
    {
        // The bound Kotlin enum is a reference type; compare via reference
        // equality against the static instances on NativeBackendKind.
        if (k.Equals(NativeBackendKind.Auto)) return BackendKind.Auto;
        if (k.Equals(NativeBackendKind.Llama)) return BackendKind.Llama;
        if (k.Equals(NativeBackendKind.MediaPipe)) return BackendKind.MediaPipe;
        if (k.Equals(NativeBackendKind.LiteRT)) return BackendKind.LiteRT;
        return BackendKind.Auto;
    }

    private static DVAIBridgeException MapJavaThrowable(Java.Lang.Throwable e)
    {
        // The Phase 3D AAR's DVAIBridgeError sealed class binds as a
        // hierarchy of Java throwables. Each subclass carries a JNI-bound
        // C# wrapper. We pattern-match on the wrapper types to map back to
        // the public DVAIBridgeException factories.
        return e switch
        {
            NativeError.AlreadyStarted ase =>
                DVAIBridgeException.AlreadyStarted(ParseManagedBackend(ase.CurrentBackend), ase.BaseUrl),
            NativeError.ConfigurationInvalid ci =>
                DVAIBridgeException.ConfigurationInvalid(ci.Message ?? string.Empty),
            NativeError.ModelLoadFailed mlf =>
                DVAIBridgeException.ModelLoadFailed(mlf.Message ?? string.Empty),
            NativeError.BackendUnavailable bu =>
                DVAIBridgeException.BackendUnavailable(ParseManagedBackend(bu.Backend), bu.Message ?? string.Empty),
            NativeError.ChecksumMismatch cm =>
                DVAIBridgeException.ChecksumMismatch(string.Empty, cm.Message ?? string.Empty),
            NativeError.DownloadFailed df =>
                DVAIBridgeException.DownloadFailed(df.Message ?? string.Empty),
            NativeError.BackendError be =>
                DVAIBridgeException.BackendError(be.Message ?? string.Empty),
            _ => DVAIBridgeException.BackendError(e.Message ?? "Unknown native error"),
        };
    }

    // ------------------------------------------------------------------
    // Continuation bridge — converts a Kotlin `suspend fun`'s
    // Continuation-form invocation into a C# `Task<T>`.
    // ------------------------------------------------------------------

    /// <summary>
    /// Java sentinel returned by a `suspend fun` invocation when the
    /// coroutine actually suspended (vs. completing synchronously). Defined
    /// in `kotlin.coroutines.intrinsics.IntrinsicsKt$COROUTINE_SUSPENDED`
    /// — at the JVM level it's a singleton instance of `kotlin.coroutines.intrinsics.CoroutineSingletons.COROUTINE_SUSPENDED`.
    /// We look it up via reflection once and compare by reference.
    /// </summary>
    private static readonly Lazy<Java.Lang.Object?> _suspendedSentinel = new(() =>
    {
        try
        {
            using var enumClass = Java.Lang.Class.ForName("kotlin.coroutines.intrinsics.CoroutineSingletons");
            // Enum constant named COROUTINE_SUSPENDED.
            var values = (Java.Lang.Object[]?)enumClass.GetMethod("values").Invoke(null);
            if (values is null) return null;
            foreach (var v in values)
            {
                if (v?.ToString() == "COROUTINE_SUSPENDED") return v;
            }
            return null;
        }
        catch
        {
            return null;
        }
    });

    private static bool IsCoroutineSuspended(Java.Lang.Object value)
    {
        var sentinel = _suspendedSentinel.Value;
        return sentinel is not null && ReferenceEquals(value, sentinel);
    }

    /// <summary>
    /// Java-side <c>kotlin.coroutines.Continuation&lt;T&gt;</c> implementation
    /// that flips a managed <see cref="TaskCompletionSource{TResult}"/> from
    /// <c>resumeWith()</c>. Subclasses <see cref="Java.Lang.Object"/> so
    /// the JNI peer is well-formed; registered against the Kotlin
    /// interface via the generated invoker.
    /// </summary>
    private sealed class TaskContinuation<T> : Java.Lang.Object, NativeContinuation
        where T : class?
    {
        private readonly TaskCompletionSource<T> _tcs;

        public TaskContinuation(TaskCompletionSource<T> tcs)
        {
            _tcs = tcs;
        }

        public NativeCoroutineContext Context => NativeEmptyContext.Instance!;

        public void ResumeWith(Java.Lang.Object? result)
        {
            try
            {
                var (success, value, failure) = UnwrapResult(result);
                if (success)
                {
                    _tcs.TrySetResult((value as T)!);
                }
                else if (failure is not null)
                {
                    // failure came back as Java.Lang.Object; JavaCast to the
                    // Throwable peer for marshalling. NativeError is the
                    // Kotlin DVAIBridgeError sealed-class hierarchy and
                    // descends from Java.Lang.Exception → Java.Lang.Throwable.
                    var thr = global::Android.Runtime.Extensions.JavaCast<Java.Lang.Throwable>(failure);
                    Exception inner = thr is NativeError ne
                        ? MapJavaThrowable(ne)
                        : thr;
                    _tcs.TrySetException(inner);
                }
                else
                {
                    _tcs.TrySetException(new InvalidOperationException("Continuation: unexpected null failure."));
                }
            }
            catch (Exception ex)
            {
                _tcs.TrySetException(ex);
            }
        }

        /// <summary>
        /// kotlin.Result is `@JvmInline value class` wrapping `Object`. A
        /// success carries the raw value (with null encoded as a sentinel
        /// we don't bother with — the AAR's suspend funs never return null);
        /// a failure is a `Result.Failure` wrapping a `Throwable`. We probe
        /// the runtime class via reflection.
        /// </summary>
        private static (bool success, Java.Lang.Object? value, Java.Lang.Object? failure) UnwrapResult(Java.Lang.Object? raw)
        {
            if (raw is null) return (true, null, null);
            try
            {
                using var cls = raw.Class;
                if (cls.Name == "kotlin.Result$Failure")
                {
                    var exField = cls.GetField("exception");
                    var thr = exField.Get(raw);
                    return (false, null, thr);
                }
            }
            catch
            {
                // Fall through — treat as success.
            }
            return (true, raw, null);
        }
    }

    /// <summary>
    /// Adapts the Java <c>ProgressListener</c> interface to a C# delegate.
    /// </summary>
    private sealed class ProgressListenerAdapter : Java.Lang.Object, NativeProgressListener
    {
        private readonly Action<ProgressEvent> _handler;

        public ProgressListenerAdapter(Action<ProgressEvent> handler)
        {
            _handler = handler;
        }

        public void OnProgress(NativeProgressEvent ev)
        {
            _handler(NativeProgressEventToManaged(ev));
        }

        private static ProgressEvent NativeProgressEventToManaged(NativeProgressEvent ev)
        {
            string? phase = null;
            double? percent = null;
            string? message = null;
            string? errorKind = null;
            string? errorMessage = null;

            switch (ev)
            {
                case NativeProgressEvent.Started s:
                    phase = s.Phase;
                    break;
                case NativeProgressEvent.Progress p:
                    phase = p.Phase;
                    percent = p.Percent >= 0 ? p.Percent * 100.0 : null;
                    message = p.Message;
                    break;
                case NativeProgressEvent.Completed c:
                    phase = c.Phase;
                    break;
                case NativeProgressEvent.Failed f:
                    phase = f.Phase;
                    if (f.Error is NativeError err)
                    {
                        errorKind = err.Class?.SimpleName ?? "Error";
                        errorMessage = err.Message;
                    }
                    break;
            }

            return new ProgressEvent(
                Kind: ParseProgressKind(ev),
                Phase: ParseProgressPhase(phase ?? string.Empty),
                Percent: percent,
                Message: message,
                ErrorKind: errorKind,
                ErrorMessage: errorMessage);
        }

        private static ProgressKind ParseProgressKind(NativeProgressEvent ev) => ev switch
        {
            NativeProgressEvent.Started => ProgressKind.Started,
            NativeProgressEvent.Progress => ProgressKind.Progress,
            NativeProgressEvent.Completed => ProgressKind.Completed,
            NativeProgressEvent.Failed => ProgressKind.Failed,
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
    }

    private sealed class ListenerDisposable : IDisposable
    {
        private ProgressListenerAdapter? _listener;

        public ListenerDisposable(ProgressListenerAdapter listener)
        {
            _listener = listener;
        }

        public void Dispose()
        {
            if (_listener is { } l)
            {
                NativeBridge.RemoveProgressListener(l);
                l.Dispose();
                _listener = null;
            }
        }
    }
}

/// <summary>
/// One-time bootstrap helper. Consumers must call
/// <see cref="Init(global::Android.Content.Context)"/> from
/// <c>Application.OnCreate</c> (MAUI: <c>MauiApplication</c>'s
/// <c>OnCreate</c> override) before the first <see cref="DVAIBridge.StartAsync"/>
/// or <see cref="DVAIBridge.DownloadModelAsync"/> call. Idempotent.
/// </summary>
public static class Bootstrap
{
    /// <summary>
    /// Stash an <see cref="global::Android.Content.Context"/> on the underlying
    /// <c>NativeDVAIBridge</c> object. Required for the MediaPipe backend
    /// and for <see cref="DVAIBridge.DownloadModelAsync"/>.
    /// </summary>
    public static void Init(global::Android.Content.Context applicationContext)
    {
        NativeBridge.Init(applicationContext);
    }
}

#else // !BINDINGS_GENERATED — placeholder when the AAR hasn't been fetched yet.

/// <summary>
/// Placeholder Bootstrap class. Real implementation under
/// <c>BINDINGS_GENERATED</c> compile flag (see header comment for
/// activation steps). Until the AAR is fetched and the binding generator
/// has run, this no-op preserves the public API surface so consumer
/// MAUI csprojs that reference the <c>DVAIBridge.Android</c> assembly
/// compile without errors.
/// </summary>
public static class Bootstrap
{
    /// <summary>No-op until BINDINGS_GENERATED is defined.</summary>
    public static void Init(global::Android.Content.Context applicationContext) { }
}

#endif // BINDINGS_GENERATED
