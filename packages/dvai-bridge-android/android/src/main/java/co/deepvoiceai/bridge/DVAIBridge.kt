package co.deepvoiceai.bridge

import android.content.Context
import co.deepvoiceai.bridge.llama.core.ModelDownloader
import co.deepvoiceai.bridge.shared.core.CorsConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File

// Aliases for the per-backend PluginState classes — they share names but
// live in distinct packages, so we can't import all three with bare names
// without collisions.
import co.deepvoiceai.bridge.llama.core.PluginState as LlamaPluginState
import co.deepvoiceai.bridge.mediapipe.core.PluginState as MediaPipePluginState
import co.deepvoiceai.bridge.litert.core.LiteRTPluginState

/**
 * The DVAIBridge Android Native SDK entry point. Singleton (Kotlin `object`)
 * — same shape as iOS `DVAIBridge.shared` and the Capacitor JS shim.
 *
 * Lifecycle:
 *
 *   1. Call [init] once from your `Application.onCreate()` (or any other
 *      one-time bootstrap) to give the bridge an `applicationContext`.
 *      [start] will throw [IllegalStateException] if you skip this.
 *   2. Call [start] with [StartOptions] — pick a backend explicitly or pass
 *      [BackendKind.Auto] to let [BackendSelector] pick from the
 *      `modelPath` extension.
 *   3. Hit `http://127.0.0.1:<port>/v1/...` for OpenAI-compatible HTTP
 *      requests, OR collect from [reactive] / [progressFlow] for in-process
 *      observables.
 *   4. Call [stop] to release the backend and free the port.
 *
 * Thread-safety: all state-mutating methods serialize through a Mutex,
 * matching the per-core `PluginState` pattern.
 */
object DVAIBridge {
    private val mutex = Mutex()
    private val broadcaster = ProgressBroadcaster()

    /** Compose- / Lifecycle-friendly observable view of the running state. */
    val reactive: DVAIBridgeReactiveState = DVAIBridgeReactiveState()

    /** Shared progress-event stream. Idiomatic Kotlin surface. */
    val progressFlow: SharedFlow<ProgressEvent> get() = broadcaster.flow

    @Volatile private var applicationContext: Context? = null
    @Volatile private var activePlugin: Any? = null
    @Volatile private var activeBackend: BackendKind? = null
    @Volatile private var activeServer: BoundServer? = null

    /**
     * One-time bootstrap. Stores [applicationContext] for backends that need
     * a Context (currently the MediaPipe backend). Idempotent — additional
     * calls are no-ops.
     */
    @JvmStatic
    fun init(applicationContext: Context) {
        if (this.applicationContext == null) {
            this.applicationContext = applicationContext.applicationContext
        }
    }

    /**
     * Boot the embedded HTTP server with the chosen backend. Throws
     * [DVAIBridgeError.AlreadyStarted] if a previous start() hasn't been
     * paired with a [stop]. Throws [DVAIBridgeError.BackendUnavailable] if
     * the runtime can't satisfy the requested backend.
     */
    suspend fun start(opts: StartOptions): BoundServer = mutex.withLock {
        activeServer?.let { server ->
            throw DVAIBridgeError.AlreadyStarted(server.backend, server.baseUrl)
        }
        val resolved = BackendSelector.resolve(opts)
        if (resolved == BackendKind.Auto) {
            // Should be unreachable — BackendSelector.resolve is total for non-Auto.
            throw DVAIBridgeError.ConfigurationInvalid("BackendSelector returned Auto; cannot dispatch.")
        }
        broadcaster.emit(ProgressEvent.Started(phase = "start"))

        val server: BoundServer = try {
            when (resolved) {
                BackendKind.Llama -> startLlama(opts)
                BackendKind.MediaPipe -> startMediaPipe(opts)
                BackendKind.LiteRT -> startLiteRT(opts)
                BackendKind.Auto -> error("unreachable")
            }
        } catch (e: DVAIBridgeError) {
            broadcaster.emit(ProgressEvent.Failed(phase = "start", error = e))
            throw e
        } catch (e: Throwable) {
            val wrapped = DVAIBridgeError.BackendError(e)
            broadcaster.emit(ProgressEvent.Failed(phase = "start", error = wrapped))
            throw wrapped
        }

        activeServer = server
        activeBackend = resolved
        reactive.onStarted(server)
        broadcaster.emit(ProgressEvent.Completed(phase = "start"))
        return server
    }

    private suspend fun startLlama(opts: StartOptions): BoundServer {
        val plugin = LlamaPluginState()
        val result = plugin.start(opts.toMap())
        activePlugin = plugin
        return result.toBoundServer(BackendKind.Llama)
    }

    private suspend fun startMediaPipe(opts: StartOptions): BoundServer {
        val ctx = applicationContext
            ?: throw DVAIBridgeError.ConfigurationInvalid(
                "DVAIBridge.init(context) must be called before start() for the MediaPipe backend.",
            )
        val plugin = MediaPipePluginState()
        // MediaPipe PluginState takes context as a per-start arg (not a ctor arg)
        // because the backend re-resolves context at every start to support
        // async-attach lifecycles in Capacitor consumer apps.
        val result = plugin.start(opts.toMap(), ctx)
        activePlugin = plugin
        return result.toBoundServer(BackendKind.MediaPipe)
    }

    private suspend fun startLiteRT(opts: StartOptions): BoundServer {
        val plugin = LiteRTPluginState()
        val result = plugin.start(opts.toMap())
        activePlugin = plugin
        return result.toBoundServer(BackendKind.LiteRT)
    }

    /** Stop the active backend. Idempotent — safe to call when nothing is running. */
    suspend fun stop() = mutex.withLock {
        val plugin = activePlugin ?: return@withLock
        when (plugin) {
            is LlamaPluginState -> plugin.stop()
            is MediaPipePluginState -> plugin.stop()
            is LiteRTPluginState -> plugin.stop()
        }
        activePlugin = null
        activeBackend = null
        activeServer = null
        reactive.onStopped()
    }

    /** Synchronous read of the most-recent state. */
    @JvmStatic
    fun status(): StatusInfo {
        val server = activeServer
        return StatusInfo(
            running = server != null,
            baseUrl = server?.baseUrl,
            backend = server?.backend,
            modelId = server?.modelId,
        )
    }

    /**
     * Download a model file with sha256 verification. Wraps llama-core's
     * `ModelDownloader` (resumable HTTP Range request via OkHttp). Available
     * regardless of the chosen backend — the MediaPipe / LiteRT backends
     * use the same downloader to pull their .task / .tflite checkpoints.
     */
    suspend fun downloadModel(opts: DownloadOptions): DownloadResult {
        val ctx = applicationContext
            ?: throw DVAIBridgeError.ConfigurationInvalid(
                "DVAIBridge.init(context) must be called before downloadModel().",
            )
        broadcaster.emit(ProgressEvent.Started(phase = "download"))
        val downloader = ModelDownloader(ctx)
        return try {
            // ModelDownloader.downloadModel is BLOCKING — bounce to IO.
            val (absolutePath, _) = withContext(Dispatchers.IO) {
                downloader.downloadModel(
                    url = opts.url,
                    expectedSha256 = opts.sha256,
                    destFilename = opts.destFilename,
                    headers = emptyMap(),
                    onProgress = { bytesDone, bytesTotal ->
                        val percent = if (bytesTotal != null && bytesTotal > 0) {
                            bytesDone.toFloat() / bytesTotal.toFloat()
                        } else {
                            -1f
                        }
                        broadcaster.emit(
                            ProgressEvent.Progress(
                                phase = "download",
                                percent = percent,
                                message = "$bytesDone bytes",
                            ),
                        )
                    },
                )
            }
            val file = File(absolutePath)
            val result = DownloadResult(
                path = absolutePath,
                sha256 = opts.sha256.lowercase(),
                sizeBytes = file.length(),
            )
            broadcaster.emit(ProgressEvent.Completed(phase = "download"))
            result
        } catch (e: ModelDownloader.DownloadError.ChecksumMismatch) {
            val wrapped = DVAIBridgeError.ChecksumMismatch(e.expected, e.got)
            broadcaster.emit(ProgressEvent.Failed(phase = "download", error = wrapped))
            throw wrapped
        } catch (e: DVAIBridgeError) {
            broadcaster.emit(ProgressEvent.Failed(phase = "download", error = e))
            throw e
        } catch (e: Throwable) {
            val wrapped = DVAIBridgeError.DownloadFailed(
                e.message ?: e::class.qualifiedName ?: "unknown",
                e,
            )
            broadcaster.emit(ProgressEvent.Failed(phase = "download", error = wrapped))
            throw wrapped
        }
    }

    /** Register a Java-friendly progress callback. */
    @JvmStatic
    fun addProgressListener(listener: ProgressListener) {
        broadcaster.addListener(listener)
    }

    /** Unregister a Java-friendly progress callback. */
    @JvmStatic
    fun removeProgressListener(listener: ProgressListener) {
        broadcaster.removeListener(listener)
    }
}

/**
 * Convert [StartOptions] to the loose `Map<String, Any?>` that each
 * per-backend `PluginState` consumes. Mirrors the JS-bridge contract used
 * by Capacitor wrappers.
 */
private fun StartOptions.toMap(): Map<String, Any?> {
    val map = mutableMapOf<String, Any?>(
        "contextSize" to contextSize,
        "threads" to threads,
        "httpBasePort" to httpBasePort,
        "httpMaxPortAttempts" to httpMaxPortAttempts,
        "corsOrigin" to when (val c = corsOrigin) {
            CorsConfig.Wildcard -> "*"
            is CorsConfig.Exact -> c.origin
            is CorsConfig.Allowlist -> c.origins
        },
    )
    modelPath?.let { map["modelPath"] = it }
    tokenizerPath?.let { map["tokenizerPath"] = it }
    mmprojPath?.let { map["mmprojPath"] = it }
    chatTemplate?.let { map["chatTemplate"] = it }
    modelId?.let { map["modelId"] = it }
    map["gpuLayers"] = gpuLayers
    map["embeddingMode"] = embeddingMode
    map["visionEnabled"] = visionEnabled
    map["temperature"] = temperature.toDouble()
    map["topP"] = topP.toDouble()
    map["topK"] = topK
    map["maxNewTokens"] = maxNewTokens
    return map
}

/** Convert a per-backend `PluginState.start` return map into a [BoundServer]. */
private fun Map<String, Any?>.toBoundServer(backend: BackendKind): BoundServer = BoundServer(
    baseUrl = this["baseUrl"] as String,
    port = (this["port"] as Number).toInt(),
    backend = backend,
    modelId = this["modelId"] as? String ?: "",
)
