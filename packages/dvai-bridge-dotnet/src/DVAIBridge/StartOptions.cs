namespace DVAIBridge;

/// <summary>
/// Configuration passed to <see cref="DVAIBridge.StartAsync(StartOptions, System.Threading.CancellationToken)"/>.
/// Mirrors the field set of the iOS <c>DVAIBridgeConfig</c> Swift struct and the
/// Android <c>StartOptions</c> Kotlin data class. All fields except
/// <see cref="Backend"/> are optional; the facade lets the native SDK fill
/// defaults via the <c>BackendSelector</c> path.
/// </summary>
public sealed record StartOptions
{
    /// <summary>Inference backend. Required. Use <see cref="BackendKind.Auto"/> to resolve at runtime.</summary>
    public required BackendKind Backend { get; init; }

    /// <summary>
    /// Absolute path to the model checkpoint on disk. Required for every
    /// backend except those that resolve a default model from disk via
    /// <see cref="ModelId"/> (e.g. MLX HuggingFace IDs).
    /// </summary>
    public string? ModelPath { get; init; }

    /// <summary>Optional separate tokenizer file (e.g. SentencePiece <c>tokenizer.model</c>).</summary>
    public string? TokenizerPath { get; init; }

    /// <summary>
    /// Optional multi-modal projection file path. Currently used by the
    /// llama.cpp backend's <c>llava</c>-style models.
    /// </summary>
    public string? MmprojPath { get; init; }

    /// <summary>
    /// Optional chat template override. When null the native SDK falls back to
    /// the model's metadata or the per-backend default.
    /// </summary>
    public string? ChatTemplate { get; init; }

    /// <summary>Optional model identifier surfaced via <c>/v1/models</c>. Defaults to the filename.</summary>
    public string? ModelId { get; init; }

    /// <summary>Maximum context length in tokens. Defaults to the backend's preferred value when null.</summary>
    public int? ContextSize { get; init; }

    /// <summary>Number of CPU threads. Defaults to the backend's preferred value when null.</summary>
    public int? Threads { get; init; }

    /// <summary>Number of layers to offload to GPU. Defaults to the backend's preferred value when null.</summary>
    public int? GpuLayers { get; init; }

    /// <summary>Preferred HTTP port. Defaults to a free ephemeral port when null.</summary>
    public int? HttpBasePort { get; init; }

    /// <summary>Number of port-bind retries before giving up. Defaults to 16 when null.</summary>
    public int? HttpMaxPortAttempts { get; init; }

    /// <summary>
    /// CORS origin for the embedded HTTP server. Pass <c>"*"</c> for the
    /// wildcard (default). Pass an exact origin or a comma-joined allowlist
    /// to lock the server down.
    /// </summary>
    public string? CorsOrigin { get; init; }

    /// <summary>Sampling temperature. Defaults to the backend's preferred value when null.</summary>
    public double? Temperature { get; init; }

    /// <summary>Top-p (nucleus) sampling. Defaults to the backend's preferred value when null.</summary>
    public double? TopP { get; init; }

    /// <summary>Top-k sampling. Defaults to the backend's preferred value when null.</summary>
    public int? TopK { get; init; }

    /// <summary>Maximum new tokens per request. Defaults to the backend's preferred value when null.</summary>
    public int? MaxNewTokens { get; init; }

    /// <summary>Embedding-mode flag — when true the server exposes <c>/v1/embeddings</c>.</summary>
    public bool EmbeddingMode { get; init; }

    /// <summary>Vision-enabled flag — when true the server accepts multi-modal requests.</summary>
    public bool VisionEnabled { get; init; }

    /// <summary>
    /// Optional distributed-inference (offload) configuration. When non-null
    /// and <see cref="OffloadConfig.Enabled"/> is <c>true</c>, the bridge
    /// runs LAN discovery (mDNS) for sibling devices, surfaces a
    /// <see cref="DVAIBridge.PairingRequests"/> stream for host-app UI,
    /// and persists capability + pairing data under
    /// <c>Environment.SpecialFolder.LocalApplicationData/dvai-bridge/</c>.
    /// Unset (the default) preserves v2.x behaviour exactly — offload is
    /// opt-in at v3.0.
    /// </summary>
    public OffloadConfig? Offload { get; init; }

    /// <summary>
    /// Optional path to a DVAI-Bridge offline license file (signed JWT).
    /// When unset, the validator falls back to <c>DVAI_LICENSE_PATH</c>,
    /// <c>DVAI_LICENSE_TOKEN</c>, <c>AppContext.BaseDirectory/dvai-license.jwt</c>,
    /// and <c>%LOCALAPPDATA%/dvai-bridge/dvai-license.jwt</c> in turn.
    /// See <see cref="License.LicenseValidator"/>.
    /// </summary>
    public string? LicenseKeyPath { get; init; }

    /// <summary>
    /// Optional inline license token (signed JWT string). Wins over
    /// <see cref="LicenseKeyPath"/> and every env-var / auto-discovery
    /// source. Useful for serverless / container deployments that inject
    /// the license via secret rather than file.
    /// See <see cref="License.LicenseValidator"/>.
    /// </summary>
    public string? LicenseToken { get; init; }
}
