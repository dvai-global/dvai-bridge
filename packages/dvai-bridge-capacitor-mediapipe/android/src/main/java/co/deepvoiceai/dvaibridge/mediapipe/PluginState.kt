package co.deepvoiceai.dvaibridge.mediapipe

import android.content.Context
import com.getcapacitor.JSObject
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Owns the running state of the capacitor-mediapipe plugin: the
 * [MediaPipeBridge] inference engine, the HTTP server, and model metadata.
 * All access is serialized through the [Mutex] so concurrent start/stop calls
 * from the JS bridge can never race against the underlying MediaPipe engine
 * (which is not safe to construct twice in parallel).
 *
 * Differs from [co.deepvoiceai.dvaibridge.llama.PluginState] in three ways:
 *  - No `mmprojPath` / `gpuLayers` / `contextSize` / `threads` opts —
 *    MediaPipe `tasks-genai` doesn't expose those knobs.
 *  - No `embeddingMode` opt — MediaPipe LLM has no embeddings path
 *    (handler returns 400 with a redirect to the llama backend).
 *  - Adds a `visionEnabled` opt that wires the bridge with
 *    `setMaxNumImages` and toggles the [MediaPipeHandlers.visionCapable]
 *    flag so `image_url` parts route through `addImage` instead of returning
 *    a 400.
 */
class PluginState {
    private val mutex = Mutex()
    private var server: HttpServer? = null
    private var bridge: MediaPipeBridge? = null
    private var modelId: String = ""
    private var isRunning: Boolean = false
    private var baseUrl: String? = null
    private var port: Int? = null

    suspend fun start(opts: JSObject, context: Context): JSObject = mutex.withLock {
        if (isRunning) stopInternal()

        val modelPath = opts.getString("modelPath")?.takeIf { it.isNotEmpty() }
            ?: throw IllegalArgumentException("modelPath is required for mediapipe backend")

        val maxTokens = opts.getInteger("maxTokens") ?: 2048
        val visionEnabled = opts.getBoolean("visionEnabled", false) ?: false
        val httpBasePort = opts.getInteger("httpBasePort") ?: 38883
        val httpMaxPortAttempts = opts.getInteger("httpMaxPortAttempts") ?: 16
        val corsConfig = parseCors(opts.opt("corsOrigin"))
        val resolvedModelId = opts.getString("modelId")?.takeIf { it.isNotEmpty() }
            ?: deriveModelId(modelPath)

        // Construct the MediaPipe bridge. The engine itself is loaded lazily
        // on first use, so the handler set is wired before any heavy native
        // initialization happens — failures then surface on first inference.
        val newBridge = MediaPipeBridge(
            context = context,
            modelPath = modelPath,
            maxTokens = maxTokens,
            visionEnabled = visionEnabled,
        )

        val handlers = MediaPipeHandlers(
            bridge = newBridge,
            modelId = resolvedModelId,
            visionCapable = visionEnabled,
        )
        val ctx = HandlerContext(modelId = resolvedModelId, backendName = "mediapipe")

        val newServer = HttpServer()
        val boundPort = try {
            newServer.startWithRoutes(
                basePort = httpBasePort,
                maxAttempts = httpMaxPortAttempts,
                host = "127.0.0.1",
                handlers = handlers,
                ctx = ctx,
                corsConfig = corsConfig,
            )
        } catch (t: Throwable) {
            // Bind failed — release the bridge engine if we already booted it
            // so we don't leak native resources.
            runCatching { newBridge.close() }
            throw t
        }

        this.bridge = newBridge
        this.server = newServer
        this.modelId = resolvedModelId
        this.port = boundPort
        this.baseUrl = "http://127.0.0.1:$boundPort/v1"
        this.isRunning = true

        return@withLock JSObject().apply {
            put("baseUrl", "http://127.0.0.1:$boundPort/v1")
            put("port", boundPort)
            put("backend", "mediapipe")
            put("modelId", resolvedModelId)
        }
    }

    suspend fun stop() = mutex.withLock { stopInternal() }

    private suspend fun stopInternal() {
        server?.stop()
        runCatching { bridge?.close() }
        server = null
        bridge = null
        modelId = ""
        baseUrl = null
        port = null
        isRunning = false
    }

    fun statusInfo(): JSObject = JSObject().apply {
        put("running", isRunning)
        baseUrl?.let { put("baseUrl", it) }
        if (isRunning) put("backend", "mediapipe")
    }

    private fun parseCors(raw: Any?): CorsConfig = when (raw) {
        is String -> if (raw == "*") CorsConfig.Wildcard else CorsConfig.Exact(raw)
        is List<*> -> CorsConfig.Allowlist(raw.filterIsInstance<String>())
        else -> CorsConfig.Wildcard
    }

    /**
     * Best-effort default model id from a `.task` path: strip the directory
     * prefix and the `.task` extension. Falls back to the literal path if no
     * separators are present.
     */
    private fun deriveModelId(modelPath: String): String {
        val name = modelPath.substringAfterLast('/').substringAfterLast('\\')
        val stripped = name.removeSuffix(".task")
        return stripped.ifEmpty { "mediapipe-default" }
    }
}
