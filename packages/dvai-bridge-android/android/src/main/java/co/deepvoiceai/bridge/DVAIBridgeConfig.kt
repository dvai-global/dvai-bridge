package co.deepvoiceai.bridge

import co.deepvoiceai.bridge.shared.core.CorsConfig
import co.deepvoiceai.bridge.shared.core.offload.OffloadConfig

/**
 * Options accepted by [DVAIBridge.start]. Mirrors the iOS DVAIBridge
 * `StartOptions` struct + the Capacitor JS shim's StartOptions.
 *
 * @param backend             Which backend to use. [BackendKind.Auto] resolves
 *                            via [BackendSelector] at start-time.
 * @param modelPath           Filesystem path to the model checkpoint. Required
 *                            for Llama (.gguf), MediaPipe (.task), and LiteRT
 *                            (.tflite / .litertlm) backends.
 * @param tokenizerPath       Filesystem path to a directory containing
 *                            tokenizer.json (and optional tokenizer_config.json).
 *                            Required for the LiteRT backend; ignored otherwise.
 * @param mmprojPath          Optional multimodal projector path for Llama
 *                            (vision/audio LLMs).
 * @param chatTemplate        Optional Jinja chat template override (Llama backend
 *                            only). Falls back to the model's bundled template.
 * @param gpuLayers           Llama backend: number of transformer layers to
 *                            offload to GPU (Vulkan / OpenCL on supported
 *                            devices). 99 = all layers, 0 = CPU only. Ignored
 *                            by other backends.
 * @param contextSize         Context window in tokens. Defaults to 2048.
 * @param threads             CPU thread count for the inference loop. Llama
 *                            uses this directly; LiteRT/MediaPipe pick their
 *                            own threading by default.
 * @param embeddingMode       Llama backend: open the model in
 *                            embedding-extraction mode rather than completion
 *                            mode. Mutually exclusive with chat completion.
 * @param visionEnabled       MediaPipe backend: open the LiteRT-LM EngineConfig
 *                            with `visionBackend` enabled.
 * @param temperature         LiteRT backend: sampling temperature (0 = greedy).
 * @param topP                LiteRT backend: nucleus sampling cutoff (1 = disabled).
 * @param topK                LiteRT backend: top-K truncation (0 = disabled).
 * @param maxNewTokens        LiteRT backend: hard cap on tokens generated per request.
 * @param httpBasePort        First port the HTTP server tries to bind. Defaults
 *                            to 38883 (matches the rest of the dvai-bridge family).
 * @param httpMaxPortAttempts Number of consecutive ports to try before giving
 *                            up. Defaults to 16.
 * @param corsOrigin          CORS allow-origin policy. See [CorsConfig].
 *                            Defaults to wildcard.
 * @param modelId             Optional override for the model id surfaced via
 *                            `/v1/models`. Defaults to the file name minus
 *                            extension when null.
 */
data class StartOptions(
    val backend: BackendKind = BackendKind.Auto,
    val modelPath: String? = null,
    val tokenizerPath: String? = null,
    val mmprojPath: String? = null,
    val chatTemplate: String? = null,
    val gpuLayers: Int = 99,
    val contextSize: Int = 2048,
    val threads: Int = 4,
    val embeddingMode: Boolean = false,
    val visionEnabled: Boolean = false,
    val temperature: Float = 0f,
    val topP: Float = 1f,
    val topK: Int = 0,
    val maxNewTokens: Int = 512,
    val httpBasePort: Int = 38883,
    val httpMaxPortAttempts: Int = 16,
    val corsOrigin: CorsConfig = CorsConfig.Wildcard,
    val modelId: String? = null,
    /**
     * Phase 3 — opt-in distributed inference / device offload. When
     * `enabled = true`, [DVAIBridge] spins up an [NsdDiscovery] +
     * [NsdAdvertiser], a [CapabilityCache], and a [PairingPolicy]
     * whose `requests` Flow is exposed via `DVAIBridge.pairingRequests`
     * for the host UI. Default null = behave exactly like v2.x.
     */
    val offload: OffloadConfig? = null,
    /**
     * v3.3 — offline JWT license validator config. When non-null, the
     * SDK loads the JWT from this filesystem path and verifies it at
     * startup. Auto-discovery (assets/, res/raw/, filesDir/) runs when
     * BOTH this AND [licenseToken] are null.
     *
     * Production Android builds without a valid license throw
     * [co.deepvoiceai.bridge.license.LicenseRequiredError] from
     * [DVAIBridge.start]. Debug builds (`hostBuildConfigDebug = true`
     * or `ApplicationInfo.FLAG_DEBUGGABLE`) skip validation entirely.
     */
    val licenseKeyPath: String? = null,
    /**
     * v3.3 — inline JWT license token. Overrides every other discovery
     * source. Useful for CI / test contexts where reading a file isn't
     * practical and operators inject via env var or build config.
     */
    val licenseToken: String? = null,
    /**
     * v3.3 — the host app's `BuildConfig.DEBUG` value, passed through to
     * the license validator's dev-mode bypass. When true the validator
     * returns `FreeDev` without trying to verify anything; when false (or
     * null) the validator falls back to `ApplicationInfo.FLAG_DEBUGGABLE`.
     *
     * Pass `BuildConfig.DEBUG` from your app module here — the validator
     * lives in this library module whose own `BuildConfig.DEBUG` never
     * reflects the host app's state.
     */
    val hostBuildConfigDebug: Boolean? = null,
)

/** Options for [DVAIBridge.downloadModel]. */
data class DownloadOptions(
    val url: String,
    val sha256: String,
    val destFilename: String,
)

/** Result of a successful [DVAIBridge.downloadModel] call. */
data class DownloadResult(
    val path: String,
    val sha256: String,
    val sizeBytes: Long,
)
