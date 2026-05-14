package co.deepvoiceai.bridge

import android.content.Context
import android.os.Build
import co.deepvoiceai.bridge.license.LicenseStatus
import co.deepvoiceai.bridge.license.LicenseValidator
import co.deepvoiceai.bridge.llama.core.ModelDownloader
import co.deepvoiceai.bridge.shared.core.CorsConfig
import co.deepvoiceai.bridge.shared.core.capability.CapabilityCache
import co.deepvoiceai.bridge.shared.core.capability.DeviceID
import co.deepvoiceai.bridge.shared.core.capability.CapabilityPrecheck
import co.deepvoiceai.bridge.shared.core.capability.DeviceCapabilityHints
import co.deepvoiceai.bridge.shared.core.capability.PrecheckMode
import co.deepvoiceai.bridge.shared.core.discovery.NsdAdvertiser
import co.deepvoiceai.bridge.shared.core.discovery.NsdDiscovery
import co.deepvoiceai.bridge.shared.core.discovery.PeerTxtKeys
import co.deepvoiceai.bridge.shared.core.offload.OffloadConfig
import co.deepvoiceai.bridge.shared.core.pairing.PairingPolicy
import kotlinx.serialization.Serializable
import co.deepvoiceai.bridge.shared.core.pairing.PairingRequest
import co.deepvoiceai.bridge.shared.core.pairing.PairingStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
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

    // -------------------------------------------------------------------------
    // Phase 3 Task 8b — distributed inference / device offload
    // -------------------------------------------------------------------------
    @Volatile private var nsdDiscovery: NsdDiscovery? = null
    @Volatile private var nsdAdvertiser: NsdAdvertiser? = null
    @Volatile private var capabilityCache: CapabilityCache? = null
    @Volatile private var pairingStore: PairingStore? = null
    @Volatile private var pairingPolicy: PairingPolicy? = null

    // -------------------------------------------------------------------------
    // v3.2 Phase 5 — pre-routing offload proxy
    // -------------------------------------------------------------------------
    @Volatile private var offloadProxy: OffloadProxy? = null
    /** Set true after the precheck classifies the device into offload-only.
     *  In that mode no model is downloaded / loaded; every request forwards
     *  to a paired peer. */
    @Volatile var offloadOnlyMode: Boolean = false
        private set

    /**
     * Hot stream of [PairingRequest]s — surfaced to host UI when a peer
     * device requests to pair with this device over the LAN. Compose
     * collects `lifecycleScope.launch { DVAIBridge.pairingRequests.collect ... }`.
     *
     * Empty / never-emits when offload is disabled.
     */
    val pairingRequests: SharedFlow<PairingRequest>
        get() = pairingPolicy?.requests ?: emptyPairingRequests

    private val emptyPairingRequests: SharedFlow<PairingRequest> =
        MutableSharedFlow<PairingRequest>(replay = 0, extraBufferCapacity = 1).asSharedFlow()

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
     * v3.2 — pre-init hardware assessment.
     *
     * Returns a JSON-serializable description of how this device would
     * handle local inference, BEFORE any model download/load. The SDK
     * itself never shows UI for hardware decisions — consumer apps
     * call this and decide their own UX based on the returned `mode`:
     *
     *   - `OK`           → device can comfortably run the model
     *                      locally; [start] proceeds normally.
     *   - `OFFLOAD_ONLY` → device can run but slowly (below
     *                      `minLocalCapability`); [start] skips the
     *                      model load and routes every request to
     *                      a paired peer.
     *   - `TOO_WEAK`     → device is below the hardware floor (3
     *                      tok/s by default); [start] also skips
     *                      the model load. Consumers typically bail
     *                      rather than even calling [start].
     *
     * The result is `kotlinx.serialization.Serializable` so it can be
     * passed to a Capacitor / React Native bridge as JSON or stored
     * directly. Pass overrides for [hardwareMinimum] and
     * [minLocalCapability] to mirror your `OffloadConfig`.
     */
    @JvmStatic
    fun assessHardware(
        hardwareMinimum: Double = 3.0,
        minLocalCapability: Double = 10.0,
    ): HardwareAssessment {
        val ctx = applicationContext
            ?: throw DVAIBridgeError.ConfigurationInvalid(
                "DVAIBridge.init(context) must be called before assessHardware().",
            )
        val precheck = CapabilityPrecheck.assess(
            context = ctx,
            thresholds = CapabilityPrecheck.Thresholds(
                hardwareMinimum = hardwareMinimum,
                minLocalCapability = minLocalCapability,
            ),
        )
        return HardwareAssessment(
            mode = precheck.mode,
            tokPerSec = precheck.tokPerSec,
            reason = precheck.reason,
            hints = precheck.hints,
        )
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

        // ---------------------------------------------------------------
        // v3.3 — offline JWT license validation.
        //
        // BSL 1.1 enforcement: in production (non-DEBUG) Android builds
        // the SDK refuses to start without a valid commercial / trial
        // license. Debug builds (BuildConfig.DEBUG=true, FLAG_DEBUGGABLE,
        // or DVAI_FORCE_DEV=1) skip enforcement entirely.
        //
        // Runs BEFORE backend init so failed validation aborts cleanly
        // without downloading a model or binding a port.
        // ---------------------------------------------------------------
        val ctxForLicense = applicationContext
            ?: throw DVAIBridgeError.ConfigurationInvalid(
                "DVAIBridge.init(context) must be called before start().",
            )
        val licenseStatus: LicenseStatus = try {
            LicenseValidator(
                context = ctxForLicense,
                token = opts.licenseToken,
                path = opts.licenseKeyPath,
                hostBuildConfigDebug = opts.hostBuildConfigDebug,
            ).validateAndAssert()
        } catch (e: co.deepvoiceai.bridge.license.LicenseRequiredError) {
            // Surface the license failure on the progress stream so host UIs
            // can render the error inline; wrap as BackendError because the
            // progress sealed class' Failed.error is DVAIBridgeError-typed.
            // The original LicenseRequiredError is rethrown unchanged.
            broadcaster.emit(
                ProgressEvent.Failed(
                    phase = "license",
                    error = DVAIBridgeError.BackendError(e),
                ),
            )
            throw e
        }

        // ---------------------------------------------------------------
        // v3.2 Phase 5 — pre-init capability gate.
        //
        // Runs the heuristic (no model required) and decides:
        //   - TOO_WEAK     → call host onHardwareTooWeak hook + throw
        //   - OFFLOAD_ONLY → skip backend init; bring up only proxy +
        //                    discovery + pairing
        //   - OK           → start backend normally + proxy in front
        //
        // Only executes when offload.enabled === true; otherwise the
        // existing v3.1 path runs unchanged.
        // ---------------------------------------------------------------
        val offload = opts.offload?.takeIf { it.enabled }
        offloadOnlyMode = false
        if (offload != null) {
            val ctx = applicationContext
                ?: throw DVAIBridgeError.ConfigurationInvalid(
                    "DVAIBridge.init(context) must be called before start() with offload enabled.",
                )
            val precheck = CapabilityPrecheck.assess(
                context = ctx,
                thresholds = CapabilityPrecheck.Thresholds(
                    hardwareMinimum = offload.hardwareMinimum,
                    minLocalCapability = offload.minLocalCapability,
                ),
            )
            broadcaster.emit(
                ProgressEvent.Progress(
                    phase = "precheck",
                    percent = -1f,
                    message = "[DVAI/precheck] ${precheck.mode}: ${precheck.reason}",
                ),
            )
            // v3.2 — both TOO_WEAK and OFFLOAD_ONLY collapse to "skip
            // backend init" from the SDK's perspective. The SDK does
            // NOT throw and does NOT show any UI; consumers query
            // [assessHardware] ahead of start() and decide their own UX.
            offloadOnlyMode =
                precheck.mode == PrecheckMode.OFFLOAD_ONLY ||
                precheck.mode == PrecheckMode.TOO_WEAK
        }

        // Determine the backend's internal port. When the proxy is in
        // front, shift the backend off the user-facing port to avoid
        // collision: backend at httpBasePort + 100, proxy at httpBasePort.
        val proxyEnabled = offload != null
        val backendInternalBasePort = if (proxyEnabled) opts.httpBasePort + 100 else opts.httpBasePort
        val backendOpts = if (proxyEnabled && !offloadOnlyMode) {
            opts.copy(httpBasePort = backendInternalBasePort)
        } else {
            opts
        }

        // ---- Backend init (skipped in offload-only mode) ----
        val backendServer: BoundServer? = if (offloadOnlyMode) {
            broadcaster.emit(
                ProgressEvent.Progress(
                    phase = "backend",
                    percent = -1f,
                    message = "[DVAI/precheck] OFFLOAD_ONLY — backend init skipped (no model download/load).",
                ),
            )
            null
        } else {
            try {
                when (resolved) {
                    BackendKind.Llama -> startLlama(backendOpts)
                    BackendKind.MediaPipe -> startMediaPipe(backendOpts)
                    BackendKind.LiteRT -> startLiteRT(backendOpts)
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
        }

        // ---- Public-facing server: backend (no offload) OR proxy (offload) ----
        val rawServer: BoundServer = if (proxyEnabled) {
            // Bring up offload services (discovery + pairing) BEFORE proxy
            // start so the proxy can read the live peer list on first request.
            try {
                initOffload(offload!!, backendServer ?: BoundServer(
                    baseUrl = "http://127.0.0.1:0",
                    port = 0,
                    backend = resolved,
                    modelId = "",
                ))
            } catch (e: Throwable) {
                broadcaster.emit(
                    ProgressEvent.Progress(
                        phase = "start",
                        percent = -1f,
                        message = "[DVAI/offload] init skipped: ${e.message}",
                    ),
                )
            }

            val proxy = OffloadProxy(
                backendBaseUrl = backendServer?.baseUrl,
                offloadConfig = offload!!,
                pairingPolicy = pairingPolicy,
                discovery = nsdDiscovery,
                appId = opts.modelId ?: "co.deepvoiceai.dvai-bridge",
                selfDeviceId = applicationContext?.let { DeviceID.get(it) } ?: "unknown",
            )
            val boundProxyPort = proxy.start(basePort = opts.httpBasePort, maxAttempts = opts.httpMaxPortAttempts)
            offloadProxy = proxy
            BoundServer(
                baseUrl = proxy.baseUrl()!!,
                port = boundProxyPort,
                backend = resolved,
                modelId = backendServer?.modelId.orEmpty(),
            )
        } else {
            backendServer!!
        }

        // Attach the license status so host apps can inspect the
        // licensee / expiry without re-running the validator.
        val server: BoundServer = rawServer.copy(licenseStatus = licenseStatus)

        activeServer = server
        activeBackend = resolved

        // When the proxy is NOT in use, run the legacy offload-init path
        // for parity with v3.0/v3.1 consumers that have offload set but
        // not enabled (or for non-offload consumers — initOffload is a no-op
        // when offload == null, but defensively gate on enabled here too).
        if (!proxyEnabled) {
            opts.offload?.takeIf { it.enabled }?.let { off ->
                try {
                    initOffload(off, server)
                } catch (e: Throwable) {
                    broadcaster.emit(
                        ProgressEvent.Progress(
                            phase = "start",
                            percent = -1f,
                            message = "[DVAI/offload] init skipped: ${e.message}",
                        ),
                    )
                }
            }
        }

        reactive.onStarted(server)
        broadcaster.emit(ProgressEvent.Completed(phase = "start"))
        return server
    }

    /**
     * Initialise the discovery, capability cache, and pairing layer for
     * the current run. Called from [start] when [OffloadConfig.enabled]
     * is true. Idempotent within a single start/stop cycle.
     */
    private fun initOffload(off: OffloadConfig, server: BoundServer) {
        val ctx = applicationContext
            ?: throw DVAIBridgeError.ConfigurationInvalid(
                "DVAIBridge.init(context) must be called before start() with offload enabled.",
            )
        val deviceId = DeviceID.get(ctx)
        capabilityCache = CapabilityCache(ctx)
        val store = PairingStore(ctx).also { pairingStore = it }
        pairingPolicy = PairingPolicy(store)

        if (off.discoverLAN) {
            val discovery = NsdDiscovery(ctx, selfDeviceId = deviceId)
            try {
                discovery.start()
                nsdDiscovery = discovery
            } catch (e: Throwable) {
                broadcaster.emit(
                    ProgressEvent.Progress(
                        phase = "start",
                        percent = -1f,
                        message = "[DVAI/discovery] start failed: ${e.message}",
                    ),
                )
            }

            val advertiser = NsdAdvertiser(ctx)
            val txt = mutableMapOf(
                PeerTxtKeys.DEVICE_ID to deviceId,
                PeerTxtKeys.DEVICE_NAME to deviceNameFromBuild(),
                PeerTxtKeys.DVAI_VERSION to LIBRARY_VERSION,
            )
            if (server.modelId.isNotEmpty()) txt[PeerTxtKeys.MODELS] = server.modelId
            try {
                advertiser.start(
                    serviceName = "dvai-bridge-${deviceId.take(8)}",
                    port = server.port,
                    txt = txt,
                )
                nsdAdvertiser = advertiser
            } catch (e: Throwable) {
                broadcaster.emit(
                    ProgressEvent.Progress(
                        phase = "start",
                        percent = -1f,
                        message = "[DVAI/advertiser] start failed: ${e.message}",
                    ),
                )
            }
        }
    }

    private fun deviceNameFromBuild(): String =
        listOf(Build.MANUFACTURER, Build.MODEL).joinToString(" ").trim().ifEmpty { "android" }

    private val LIBRARY_VERSION: String = "3.0.0"

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
        // Tear down offload services first so peers see us drop off
        // before the HTTP port closes.
        try { nsdAdvertiser?.stop() } catch (_: Throwable) { }
        try { nsdDiscovery?.stop() } catch (_: Throwable) { }
        // v3.2 — stop the proxy *after* discovery so in-flight peer
        // forwards drain cleanly, but before the backend so consumer
        // requests stop coming in before the backend goes away.
        try { offloadProxy?.stop() } catch (_: Throwable) { }
        offloadProxy = null
        offloadOnlyMode = false
        nsdAdvertiser = null
        nsdDiscovery = null
        capabilityCache = null
        pairingPolicy = null
        pairingStore = null

        val plugin = activePlugin ?: run {
            activePlugin = null
            activeBackend = null
            activeServer = null
            reactive.onStopped()
            return@withLock
        }
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
 * v3.2 — JSON-serializable result of [DVAIBridge.assessHardware]. Returned
 * to consumer code so the app developer can decide whether to call
 * [DVAIBridge.start] and what (if anything) to surface in the UI.
 *
 * `@Serializable` so it round-trips cleanly through Capacitor / React
 * Native / Pigeon bridges as JSON without any custom converter.
 */
@Serializable
data class HardwareAssessment(
    /** Lifecycle mode the SDK would enter on [DVAIBridge.start]. */
    val mode: PrecheckMode,
    /** Estimated decode tok/s for any 1–3B-class model on this device. */
    val tokPerSec: Double,
    /** Human-readable explanation; safe to log or display. */
    val reason: String,
    /** Underlying hints used to compute the estimate. */
    val hints: DeviceCapabilityHints,
)

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
