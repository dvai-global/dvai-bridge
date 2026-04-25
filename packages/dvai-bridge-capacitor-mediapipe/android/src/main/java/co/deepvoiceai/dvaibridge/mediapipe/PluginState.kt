package co.deepvoiceai.dvaibridge.mediapipe

import android.content.Context
import com.getcapacitor.JSObject
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Owns the running state of the capacitor-mediapipe plugin: the LLM
 * inference, the HTTP server, and the model metadata. Access serialized
 * via Mutex (Kotlin's actor-equivalent for this use case).
 *
 * Phase 1 status: skeleton. `start` validates `modelPath` and then throws
 * `NotImplementedError` — the wiring to `MediaPipeHandlers` and the HTTP
 * server lands in Task 48 once the real handler set (Task 45) and vision
 * support (Task 46) are in place. The deferred fields below are kept so
 * the eventual wiring lands in a small diff.
 */
@Suppress("unused") // server/modelId/baseUrl/port populated in Task 48
class PluginState {
    private val mutex = Mutex()
    private var server: HttpServer? = null
    private var modelId: String = ""
    private var isRunning: Boolean = false
    private var baseUrl: String? = null
    private var port: Int? = null

    suspend fun start(opts: JSObject, @Suppress("UNUSED_PARAMETER") context: Context): JSObject = mutex.withLock {
        if (isRunning) stopInternal()

        val modelPath = opts.getString("modelPath")?.takeIf { it.isNotEmpty() }
            ?: throw IllegalArgumentException("modelPath is required for mediapipe backend")

        // Real wiring lands in Task 48 once MediaPipeHandlers (Task 45) and
        // vision/audio support (Task 46) are merged. For now, fail loudly so
        // anyone calling `start` against the skeleton sees exactly which task
        // they're waiting on. `context` is on the signature so Task 48 can
        // resolve files-dir paths without a Plugin.kt diff.
        @Suppress("UNUSED_VARIABLE")
        val _modelPath = modelPath
        throw NotImplementedError(
            "PluginState wiring to MediaPipeHandlers lands in Task 48"
        )
    }

    suspend fun stop() = mutex.withLock { stopInternal() }

    private fun stopInternal() {
        // server?.stop(...)  // Task 48
        server = null
        modelId = ""
        baseUrl = null
        port = null
        isRunning = false
    }

    fun statusInfo(): JSObject {
        val ret = JSObject()
        ret.put("running", isRunning)
        baseUrl?.let { ret.put("baseUrl", it) }
        if (isRunning) ret.put("backend", "mediapipe")
        return ret
    }
}
