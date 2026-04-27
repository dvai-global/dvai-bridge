package co.deepvoiceai.bridge.mediapipe.core

import android.content.Context
import co.deepvoiceai.bridge.shared.core.CorsConfig
import co.deepvoiceai.bridge.shared.core.HandlerContext
import co.deepvoiceai.bridge.shared.core.HttpServer
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Owns the running state of the MediaPipe core: the [MediaPipeBridge]
 * inference engine, the HTTP server, and model metadata. All access is
 * serialized through the [Mutex] so concurrent start/stop calls from the
 * bridge layer can never race against the underlying MediaPipe engine
 * (which is not safe to construct twice in parallel).
 *
 * Capacitor-free: opts are plain [Map<String, Any?>] and return values are
 * plain [Map<String, Any?>]. The Capacitor wrapper translates between
 * JSObject and Map before/after calling into this class.
 *
 * Differs from [co.deepvoiceai.bridge.llama.core.PluginState] in three ways:
 *  - No `mmprojPath` / `gpuLayers` / `contextSize` / `threads` opts —
 *    LiteRT-LM doesn't expose those knobs.
 *  - No `embeddingMode` opt — LiteRT-LM LLM has no embeddings path
 *    (handler returns 400 with a redirect to the llama backend).
 *  - Adds a `visionEnabled` opt that wires the bridge with
 *    `EngineConfig.visionBackend` and toggles the [MediaPipeHandlers.visionCapable]
 *    flag so `image_url` parts route through `Content.ImageBytes` instead of
 *    returning a 400.
 */
class PluginState {
    private val mutex = Mutex()
    private var server: HttpServer? = null
    private var bridge: MediaPipeBridge? = null
    private var modelId: String = ""
    private var isRunning: Boolean = false
    private var baseUrl: String? = null
    private var port: Int? = null

    suspend fun start(opts: Map<String, Any?>, context: Context): Map<String, Any?> = mutex.withLock {
        if (isRunning) stopInternal()

        val modelPath = (opts["modelPath"] as? String)?.takeIf { it.isNotEmpty() }
            ?: throw IllegalArgumentException("modelPath is required for mediapipe backend")

        val maxTokens = (opts["maxTokens"] as? Number)?.toInt() ?: 2048
        val visionEnabled = opts["visionEnabled"] as? Boolean ?: false
        val httpBasePort = (opts["httpBasePort"] as? Number)?.toInt() ?: 38883
        val httpMaxPortAttempts = (opts["httpMaxPortAttempts"] as? Number)?.toInt() ?: 16
        val corsConfig = parseCors(opts["corsOrigin"])
        val resolvedModelId = (opts["modelId"] as? String)?.takeIf { it.isNotEmpty() }
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

        return@withLock mapOf(
            "baseUrl" to "http://127.0.0.1:$boundPort/v1",
            "port" to boundPort,
            "backend" to "mediapipe",
            "modelId" to resolvedModelId,
        )
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

    fun statusInfo(): Map<String, Any?> = buildMap {
        put("running", isRunning)
        baseUrl?.let { put("baseUrl", it) }
        if (isRunning) put("backend", "mediapipe")
    }

    private fun parseCors(raw: Any?): CorsConfig = CorsConfig.fromOpt(raw)

    /**
     * Best-effort default model id from a model file path: strip the directory
     * prefix and any `.litertlm` or legacy `.task` extension. Falls back to
     * the literal path if no separators are present.
     */
    private fun deriveModelId(modelPath: String): String {
        val name = modelPath.substringAfterLast('/').substringAfterLast('\\')
        val stripped = name.removeSuffix(".litertlm").removeSuffix(".task")
        return stripped.ifEmpty { "mediapipe-default" }
    }
}
