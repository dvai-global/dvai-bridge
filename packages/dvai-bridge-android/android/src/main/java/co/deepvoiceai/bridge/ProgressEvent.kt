package co.deepvoiceai.bridge

/**
 * Progress events emitted while [DVAIBridge.start] / [DVAIBridge.downloadModel]
 * are running. Subscribe via [DVAIBridge.progressFlow] (Kotlin idiomatic) or
 * [DVAIBridge.addProgressListener] (Java-friendly callback shape).
 *
 * Mirrors iOS `ProgressEvent` 1:1.
 */
sealed class ProgressEvent {
    /** A long-running operation has started (download or model load). */
    data class Started(val phase: String) : ProgressEvent()

    /**
     * Operation is in progress. [percent] is in `[0.0, 1.0]` when known,
     * negative when indeterminate.
     */
    data class Progress(val phase: String, val percent: Float, val message: String = "") : ProgressEvent()

    /** Operation finished successfully. */
    data class Completed(val phase: String) : ProgressEvent()

    /** Operation failed; the bridge stays in its prior state. */
    data class Failed(val phase: String, val error: DVAIBridgeError) : ProgressEvent()
}
