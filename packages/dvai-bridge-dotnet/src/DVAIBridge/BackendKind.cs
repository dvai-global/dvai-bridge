namespace DVAIBridge;

/// <summary>
/// Inference backend used by <see cref="DVAIBridge.StartAsync(StartOptions, System.Threading.CancellationToken)"/>.
/// The set is the union of iOS and Android backends; the facade pre-validates
/// the value against the runtime platform and the native bindings perform
/// defense-in-depth checks of their own.
/// </summary>
public enum BackendKind
{
    /// <summary>Resolve the best available backend at runtime via <c>BackendSelector</c> on the native side.</summary>
    Auto = 0,

    /// <summary>llama.cpp via Metal (iOS) / GPU (Android). Broad-compatibility default.</summary>
    Llama = 1,

    /// <summary>
    /// Apple Foundation Models (LanguageModelSession). iOS 26+ runtime; SwiftPM-only.
    /// Selecting this on Android or under a CocoaPods-built iOS app throws
    /// <see cref="DVAIBridgeException.BackendUnavailable"/>.
    /// </summary>
    Foundation = 2,

    /// <summary>CoreML / Apple Neural Engine via <c>MLModel</c> + <c>MLState</c> (iOS 18+). iOS-only.</summary>
    CoreML = 3,

    /// <summary>
    /// MLX — Apple Silicon GPU/Neural Engine via <c>mlx-swift-lm</c>. iOS-only,
    /// Apple-Silicon device (or Apple-Silicon-host simulator) only.
    /// </summary>
    MLX = 4,

    /// <summary>Google MediaPipe LLM Inference API. Android-only.</summary>
    MediaPipe = 5,

    /// <summary>Google LiteRT (TensorFlow Lite Next) inference engine. Android-only.</summary>
    LiteRT = 6,
}

/// <summary>
/// Wire-format helpers — mirror the lowercase string names used by the native
/// SDKs (<c>"auto"</c>, <c>"llama"</c>, …) so we can round-trip via the
/// platform marshallers without committing to a specific integer encoding.
/// </summary>
public static class BackendKindExtensions
{
    /// <summary>
    /// Convert a <see cref="BackendKind"/> to its lowercase wire name
    /// (e.g. <c>BackendKind.MediaPipe</c> → <c>"mediapipe"</c>).
    /// </summary>
    public static string ToWireString(this BackendKind kind) => kind switch
    {
        BackendKind.Auto => "auto",
        BackendKind.Llama => "llama",
        BackendKind.Foundation => "foundation",
        BackendKind.CoreML => "coreml",
        BackendKind.MLX => "mlx",
        BackendKind.MediaPipe => "mediapipe",
        BackendKind.LiteRT => "litert",
        _ => throw new System.ArgumentOutOfRangeException(nameof(kind), kind, "Unknown BackendKind"),
    };

    /// <summary>
    /// Parse a lowercase wire name back into a <see cref="BackendKind"/>.
    /// Throws <see cref="System.ArgumentException"/> if the input is not a
    /// recognized backend (case-sensitive — match the native SDKs exactly).
    /// </summary>
    public static BackendKind FromWireString(string wire) => wire switch
    {
        "auto" => BackendKind.Auto,
        "llama" => BackendKind.Llama,
        "foundation" => BackendKind.Foundation,
        "coreml" => BackendKind.CoreML,
        "mlx" => BackendKind.MLX,
        "mediapipe" => BackendKind.MediaPipe,
        "litert" => BackendKind.LiteRT,
        _ => throw new System.ArgumentException($"Unknown backend wire string: '{wire}'", nameof(wire)),
    };
}
