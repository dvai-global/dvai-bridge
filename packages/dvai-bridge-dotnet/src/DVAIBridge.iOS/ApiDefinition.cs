//
// ApiDefinition.cs — Microsoft iOS binding generator contract.
//
// Each [BaseType] interface here describes an Obj-C class exposed by the
// DVAIBridgeNetBridge.xcframework. The binding generator emits a C# wrapper
// class with the same name in the DVAIBridge.iOS.Native namespace, which
// IOSNativeBridge.cs then consumes.
//
// The `[Async]` attribute on completion-handler methods generates a C#
// `Task<T>` overload alongside the manual completion-handler form. We use
// the `Async` overloads exclusively in IOSNativeBridge.cs.
//

using System;
using Foundation;
using ObjCRuntime;

namespace DVAIBridge.iOS.Native;

/// <summary>
/// Obj-C contract for the @objc Swift wrapper class
/// <c>DVAIBridgeNetBridge</c>. The binding generator emits a managed
/// <c>DVAIBridgeNetBridge</c> class in this namespace.
/// </summary>
[BaseType(typeof(NSObject), Name = "DVAIBridgeNetBridge")]
[DisableDefaultCtor]
interface DVAIBridgeNetBridge
{
    /// <summary>Singleton instance accessor.</summary>
    [Static]
    [Export("shared")]
    DVAIBridgeNetBridge Shared { get; }

    /// <summary>Start the embedded HTTP server. Generates StartAsync(NSDictionary) → Task&lt;NSDictionary&gt;.</summary>
    [Async]
    [Export("startWithConfig:completion:")]
    void Start(NSDictionary config, Action<NSDictionary, NSError> completion);

    /// <summary>Stop the embedded HTTP server. Generates StopAsync() → Task.</summary>
    [Async]
    [Export("stopWithCompletion:")]
    void Stop(Action<NSError> completion);

    /// <summary>Snapshot the current bridge state. Generates StatusAsync() → Task&lt;NSDictionary&gt;.</summary>
    [Async]
    [Export("statusWithCompletion:")]
    void Status(Action<NSDictionary, NSError> completion);

    /// <summary>Download a model file. Generates DownloadModelAsync(NSDictionary) → Task&lt;NSDictionary&gt;.</summary>
    [Async]
    [Export("downloadModelWithOptions:completion:")]
    void DownloadModel(NSDictionary options, Action<NSDictionary, NSError> completion);

    /// <summary>Subscribe to push-style progress events. Returns an opaque cancellable handle.</summary>
    [Export("subscribeProgressWithOnEvent:")]
    DVAIBridgeNetCancellable SubscribeProgress(Action<NSDictionary> onEvent);
}

/// <summary>
/// Obj-C contract for <c>DVAIBridgeNetCancellable</c> — the
/// <c>AnyCancellable</c>-wrapping handle returned by SubscribeProgress.
/// </summary>
[BaseType(typeof(NSObject), Name = "DVAIBridgeNetCancellable")]
[DisableDefaultCtor]
interface DVAIBridgeNetCancellable
{
    /// <summary>Cancel the underlying Combine subscription.</summary>
    [Export("cancel")]
    void Cancel();
}
