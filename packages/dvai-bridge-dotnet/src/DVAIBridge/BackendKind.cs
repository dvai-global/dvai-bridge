namespace DVAIBridge;

/// <summary>
/// Inference backend used by <see cref="DVAIBridge.StartAsync(StartOptions, System.Threading.CancellationToken)"/>.
/// The set is the union of every backend supported by the .NET wrapper —
/// platform-specific (iOS / Android / Catalyst / Desktop via <c>llama.cpp</c>)
/// plus .NET-specific (ONNX Runtime, ML.NET) backends. The facade pre-validates
/// the value against the runtime platform and the native bridges perform
/// defense-in-depth checks of their own.
///
/// <para>
/// IntelliSense renders enum members in declaration order — we list <c>Onnx</c>
/// before <c>MLNet</c> so consumers see the recommended ONNX path first.
/// </para>
/// </summary>
public enum BackendKind
{
    /// <summary>Resolve the best available backend at runtime via <c>BackendSelector</c> on the native side.</summary>
    Auto = 0,

    /// <summary>llama.cpp via Metal (iOS) / GPU (Android) / CPU+SIMD (Desktop). Broad-compatibility default.</summary>
    Llama = 1,

    /// <summary>
    /// Apple Foundation Models (LanguageModelSession). iOS 26+ runtime; SwiftPM-only.
    /// Selecting this on Android / Desktop / under a CocoaPods-built iOS app throws
    /// <see cref="DVAIBridgeException.BackendUnavailable"/>.
    /// </summary>
    Foundation = 2,

    /// <summary>CoreML / Apple Neural Engine via <c>MLModel</c> + <c>MLState</c> (iOS 18+). iOS / Catalyst only.</summary>
    CoreML = 3,

    /// <summary>
    /// MLX — Apple Silicon GPU/Neural Engine via <c>mlx-swift-lm</c>. iOS / Catalyst only,
    /// Apple-Silicon device (or Apple-Silicon-host simulator) only.
    /// </summary>
    MLX = 4,

    /// <summary>Google MediaPipe LLM Inference API. Android-only.</summary>
    MediaPipe = 5,

    /// <summary>Google LiteRT (TensorFlow Lite Next) inference engine. Android-only.</summary>
    LiteRT = 6,

    /// <summary>
    /// ONNX Runtime via <c>Microsoft.ML.OnnxRuntime</c> +
    /// <c>Microsoft.ML.OnnxRuntimeGenAI</c>. Cross-platform (Windows / macOS / Linux
    /// desktop AND iOS / Android / Catalyst). Requires the
    /// <c>DVAIBridge.OnnxRuntime</c> NuGet to be installed by the consumer.
    /// </summary>
    Onnx = 7,

    /// <summary>
    /// ML.NET via <c>Microsoft.ML</c> + <c>OnnxScoringEstimator</c>. Desktop primary
    /// (Windows / macOS / Linux); rejected on iOS / Android with a "use BackendKind.Onnx
    /// on mobile" hint. Requires the <c>DVAIBridge.MLNet</c> NuGet to be installed
    /// by the consumer.
    /// </summary>
    MLNet = 8,
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
        BackendKind.Onnx => "onnx",
        BackendKind.MLNet => "mlnet",
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
        "onnx" => BackendKind.Onnx,
        "mlnet" => BackendKind.MLNet,
        _ => throw new System.ArgumentException($"Unknown backend wire string: '{wire}'", nameof(wire)),
    };
}
