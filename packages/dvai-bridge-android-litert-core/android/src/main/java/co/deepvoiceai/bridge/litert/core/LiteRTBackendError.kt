package co.deepvoiceai.bridge.litert.core

/**
 * Errors surfaced by the LiteRT backend. Mirrors `CoreMLBackendError` (iOS)
 * and `MediaPipeBackendError` (mediapipe-core) — when the umbrella SDK
 * (`@dvai-bridge/android`) maps a backend exception to a public
 * `DVAIBridgeError`, it pattern-matches on the sealed type here.
 */
sealed class LiteRTBackendError(message: String) : Exception(message) {
    class ModelLoadFailed(reason: String) : LiteRTBackendError("LiteRT model load failed: $reason")
    class TokenizerLoadFailed(reason: String) : LiteRTBackendError("LiteRT tokenizer load failed: $reason")
    class GenerationFailed(reason: String) : LiteRTBackendError("LiteRT generation failed: $reason")
}
