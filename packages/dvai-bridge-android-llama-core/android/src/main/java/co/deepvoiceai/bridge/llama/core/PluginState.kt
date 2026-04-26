package co.deepvoiceai.bridge.llama.core

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Owns the running state of the llama core: the model bridge, the HTTP
 * server, and the model metadata. All access serialized through the Mutex
 * (Kotlin's actor-equivalent for this use case).
 *
 * Capacitor neutrality: this class takes plain `Map<String, Any?>` for
 * `start(opts:)` and returns the same shape from `start` / `statusInfo` so
 * the core compiles without a Capacitor dependency. The Capacitor wrapper
 * (Plugin.kt in dvai-bridge-capacitor-llama) translates JSObject ↔ Map at
 * the JS-bridge boundary.
 */
class PluginState {
    private val mutex = Mutex()
    private var server: HttpServer? = null
    private var bridge: LlamaCppBridge? = null
    private var modelId: String = ""
    private var isRunning: Boolean = false
    private var baseUrl: String? = null
    private var port: Int? = null

    suspend fun start(opts: Map<String, Any?>): Map<String, Any?> = mutex.withLock {
        if (isRunning) stopInternal()

        val modelPath = (opts["modelPath"] as? String)
            ?: throw IllegalArgumentException("modelPath is required for llama backend")
        if (modelPath.isEmpty()) throw IllegalArgumentException("modelPath is required for llama backend")

        val mmprojPath = opts["mmprojPath"] as? String
        val chatTemplate = opts["chatTemplate"] as? String
        val gpuLayers = (opts["gpuLayers"] as? Number)?.toInt() ?: 99
        val contextSize = (opts["contextSize"] as? Number)?.toInt() ?: 2048
        val threads = (opts["threads"] as? Number)?.toInt() ?: 4
        val embeddingMode = opts["embeddingMode"] as? Boolean ?: false
        val httpBasePort = (opts["httpBasePort"] as? Number)?.toInt() ?: 38883
        val httpMaxPortAttempts = (opts["httpMaxPortAttempts"] as? Number)?.toInt() ?: 16
        val corsConfig = parseCors(opts["corsOrigin"])

        // Load model via bridge.
        val newBridge = LlamaCppBridge()
        val ok = newBridge.loadModel(modelPath, mmprojPath, gpuLayers, contextSize, threads, embeddingMode)
        if (!ok) {
            throw IllegalStateException("Failed to load model at $modelPath")
        }

        // Phase 2A Pass 2: load mmproj if provided. Failure is fatal — the
        // caller asked for a multimodal model and we couldn't deliver.
        if (!mmprojPath.isNullOrEmpty()) {
            val mmprojOk = newBridge.loadMmproj(mmprojPath)
            if (!mmprojOk) {
                newBridge.unload()
                throw IllegalStateException("Failed to load mmproj at $mmprojPath")
            }
        }
        val mmprojLoaded = newBridge.isMmprojLoaded()
        val modelHasAudioEncoder = mmprojLoaded && newBridge.hasAudioEncoder()

        // Wire handlers + ctx. Phase 2A Pass 2: real flags mirrored from the
        // bridge state. embeddingMode mirrors start opts so /v1/embeddings
        // can short-circuit when off. chatTemplate is optional Jinja override;
        // null/empty falls through to the model's bundled chat template.
        val handlers = LlamaHandlers(
            bridge = newBridge,
            modelId = modelPath,
            mmprojLoaded = mmprojLoaded,
            modelHasAudioEncoder = modelHasAudioEncoder,
            embeddingMode = embeddingMode,
            chatTemplate = chatTemplate,
        )
        val ctx = HandlerContext(modelId = modelPath, backendName = "llama")

        // Bind server + install routes
        val newServer = HttpServer()
        val boundPort = newServer.startWithRoutes(
            basePort = httpBasePort,
            maxAttempts = httpMaxPortAttempts,
            host = "127.0.0.1",
            handlers = handlers,
            ctx = ctx,
            corsConfig = corsConfig,
        )

        this.bridge = newBridge
        this.server = newServer
        this.modelId = modelPath
        this.port = boundPort
        this.baseUrl = "http://127.0.0.1:$boundPort/v1"
        this.isRunning = true

        return@withLock mapOf(
            "baseUrl" to "http://127.0.0.1:$boundPort/v1",
            "port" to boundPort,
            "backend" to "llama",
            "modelId" to modelPath,
        )
    }

    suspend fun stop() = mutex.withLock { stopInternal() }

    private suspend fun stopInternal() {
        server?.stop()
        bridge?.unload()
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
        if (isRunning) put("backend", "llama")
    }

    private fun parseCors(raw: Any?): CorsConfig = when (raw) {
        is String -> if (raw == "*") CorsConfig.Wildcard else CorsConfig.Exact(raw)
        is List<*> -> CorsConfig.Allowlist(raw.filterIsInstance<String>())
        else -> CorsConfig.Wildcard
    }
}
