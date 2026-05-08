package co.deepvoiceai.bridge

/**
 * Public error surface for the DVAIBridge Android SDK. Mirrors iOS
 * `DVAIBridgeError` 1:1 in case shape so cross-platform consumers see
 * identical failure modes.
 *
 * Uses a sealed Exception hierarchy rather than a sealed-class +
 * data-classes pair so consumers can `try { ... } catch (e:
 * DVAIBridgeError.ModelLoadFailed) { ... }`.
 */
sealed class DVAIBridgeError(message: String, cause: Throwable? = null) : Exception(message, cause) {
    /** [DVAIBridge.start] called twice without a [DVAIBridge.stop] in between. */
    class AlreadyStarted(
        val currentBackend: BackendKind,
        val baseUrl: String,
    ) : DVAIBridgeError(
        "DVAIBridge is already running ($currentBackend at $baseUrl). Call stop() first.",
    )

    /** [StartOptions] is malformed (e.g. unsupported modelPath extension under Auto). */
    class ConfigurationInvalid(reason: String) : DVAIBridgeError("Configuration invalid: $reason")

    /** Backend rejected the model file or tokenizer at load time. */
    class ModelLoadFailed(reason: String, cause: Throwable? = null) : DVAIBridgeError("Model load failed: $reason", cause)

    /**
     * Backend can't run in the current environment (e.g. asking for
     * MediaPipe on a device too old for LiteRT-LM, or asking for the
     * upcoming `.foundation` Apple-Models backend on Android — it doesn't
     * exist). The umbrella throws this when [BackendSelector] resolves to
     * something the runtime doesn't support.
     */
    class BackendUnavailable(val backend: BackendKind, reason: String) : DVAIBridgeError(
        "Backend $backend is not available: $reason",
    )

    /** Generic backend failure (HTTP server bind, model inference exception). */
    class BackendError(underlying: Throwable) : DVAIBridgeError(
        "Backend error: ${underlying.message ?: underlying::class.qualifiedName}",
        underlying,
    )

    /** [DVAIBridge.downloadModel] downloaded the file but the sha256 didn't match. */
    class ChecksumMismatch(expected: String, actual: String) : DVAIBridgeError(
        "Downloaded file sha256 mismatch: expected $expected, got $actual",
    )

    /** [DVAIBridge.downloadModel] failed before completion (network, disk, HTTP error). */
    class DownloadFailed(reason: String, cause: Throwable? = null) : DVAIBridgeError("Download failed: $reason", cause)

    /**
     * v3.2 — pre-init capability gate decided this device is too weak to run
     * inference at all. Thrown by [DVAIBridge.start] AFTER the host
     * `OffloadConfig.onHardwareTooWeak` callback fires (or, if no callback was
     * supplied, after the SDK's default system-popup helper runs). The
     * consumer's catch path can offer a cloud-fallback or a "device not
     * supported" UI.
     */
    class HardwareTooWeak(
        val tokPerSec: Double,
        val hardwareMinimum: Double,
        val reason: String,
    ) : DVAIBridgeError(
        "DVAI: hardware too weak to run inference locally. " +
                "Estimated $tokPerSec tok/s; minimum is $hardwareMinimum tok/s.",
    )
}
