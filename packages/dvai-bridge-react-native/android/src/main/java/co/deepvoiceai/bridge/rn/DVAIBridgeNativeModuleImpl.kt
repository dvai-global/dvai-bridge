package co.deepvoiceai.bridge.rn

import co.deepvoiceai.bridge.BackendKind
import co.deepvoiceai.bridge.DVAIBridge
import co.deepvoiceai.bridge.DVAIBridgeError
import co.deepvoiceai.bridge.DownloadOptions
import co.deepvoiceai.bridge.ProgressEvent
import co.deepvoiceai.bridge.StartOptions
import co.deepvoiceai.bridge.shared.core.CorsConfig
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableArray
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.WritableMap
import com.facebook.react.modules.core.DeviceEventManagerModule
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch

/**
 * Shared implementation of the React Native TurboModule bridge for the
 * DVAIBridge Android SDK (Phase 3D umbrella).
 *
 * This class is `internal` and called from the platform-specific module
 * shims under `src/newarch/` (TurboModule subclass) and `src/oldarch/`
 * (legacy `ReactContextBaseJavaModule` subclass). Both shims forward into
 * a single instance of this class so the Kotlin business logic isn't
 * duplicated.
 *
 * The bridge:
 *
 *  1. Calls `DVAIBridge.init(applicationContext)` once on first construction
 *     so consumers don't have to remember to do it from their `Application`.
 *  2. Translates `ReadableMap` opts ↔ `StartOptions` / `DownloadOptions`.
 *  3. Wraps each `DVAIBridge.start(...)` / `.stop(...)` / etc. call in a
 *     coroutine and resolves / rejects the corresponding `Promise`.
 *  4. Collects from `DVAIBridge.progressFlow` and re-emits each event as
 *     a `DVAIBridgeProgress` JS event with the canonical JSON shape.
 *
 * The progress collector is started once on first JS-side
 * `addListener("DVAIBridgeProgress", …)` and torn down when listener count
 * drops to zero (mirroring the iOS Combine subscription lifecycle).
 */
internal class DVAIBridgeNativeModuleImpl(
    private val reactContext: ReactApplicationContext,
) {
    /** Coroutine scope tied to the lifetime of the React module instance. */
    private val moduleJob: Job = SupervisorJob()
    private val moduleScope: CoroutineScope = CoroutineScope(Dispatchers.Default + moduleJob)

    /** Job for the active progress-event collector, if any. */
    private var progressJob: Job? = null

    /** Listener count tracked by RN's NativeEventEmitter. */
    private var listenerCount: Int = 0

    init {
        // Defensive init — consumers SHOULD call DVAIBridge.init(this) from
        // their Application.onCreate(), but we don't want a silent
        // ConfigurationInvalid if they forget. The umbrella's init is
        // idempotent so this is safe to re-run.
        DVAIBridge.init(reactContext.applicationContext)
    }

    fun invalidate() {
        progressJob?.cancel()
        progressJob = null
        moduleScope.cancel()
    }

    // MARK: - Lifecycle methods

    fun startBridge(opts: ReadableMap, promise: Promise) {
        val startOpts = try {
            parseStartOptions(opts)
        } catch (e: DVAIBridgeError) {
            promise.rejectWith(e)
            return
        } catch (e: Throwable) {
            promise.reject("configurationInvalid", e.message ?: "Failed to parse StartOptions", e)
            return
        }

        moduleScope.launch {
            try {
                val server = DVAIBridge.start(startOpts)
                val map = Arguments.createMap().apply {
                    putString("baseUrl", server.baseUrl)
                    putInt("port", server.port)
                    putString("backend", server.backend.toJsName())
                    putString("modelId", server.modelId)
                }
                promise.resolve(map)
            } catch (e: DVAIBridgeError) {
                promise.rejectWith(e)
            } catch (e: Throwable) {
                promise.reject("backendError", e.message ?: e::class.qualifiedName ?: "unknown", e)
            }
        }
    }

    fun stopBridge(promise: Promise) {
        moduleScope.launch {
            try {
                DVAIBridge.stop()
                promise.resolve(null)
            } catch (e: DVAIBridgeError) {
                promise.rejectWith(e)
            } catch (e: Throwable) {
                promise.reject("backendError", e.message ?: e::class.qualifiedName ?: "unknown", e)
            }
        }
    }

    fun status(promise: Promise) {
        val info = DVAIBridge.status()
        val map = Arguments.createMap().apply {
            putBoolean("running", info.running)
            info.baseUrl?.let { putString("baseUrl", it) }
            info.backend?.let { putString("backend", it.toJsName()) }
            info.modelId?.let { putString("modelId", it) }
            // Port from baseUrl, when present. Mirrors the iOS impl.
            info.baseUrl?.let { url ->
                runCatching {
                    val parsed = java.net.URI(url)
                    if (parsed.port > 0) putInt("port", parsed.port)
                }
            }
        }
        promise.resolve(map)
    }

    fun downloadModel(opts: ReadableMap, promise: Promise) {
        val url = opts.getString("url")
            ?: return promise.reject("configurationInvalid", "downloadModel: missing `url`", null)
        val sha256 = opts.getString("sha256")
            ?: return promise.reject("configurationInvalid", "downloadModel: missing `sha256`", null)
        val destFilename = opts.getString("destFilename")
            ?: url.substringAfterLast('/').ifEmpty {
                return promise.reject(
                    "configurationInvalid",
                    "downloadModel: cannot derive destFilename from URL `$url`; pass it explicitly.",
                    null,
                )
            }

        moduleScope.launch {
            try {
                val result = DVAIBridge.downloadModel(
                    DownloadOptions(
                        url = url,
                        sha256 = sha256,
                        destFilename = destFilename,
                    ),
                )
                val map = Arguments.createMap().apply {
                    putString("path", result.path)
                    putString("sha256", result.sha256)
                    putDouble("sizeBytes", result.sizeBytes.toDouble())
                }
                promise.resolve(map)
            } catch (e: DVAIBridgeError) {
                promise.rejectWith(e)
            } catch (e: Throwable) {
                promise.reject("downloadFailed", e.message ?: e::class.qualifiedName ?: "unknown", e)
            }
        }
    }

    // MARK: - Event emitter housekeeping

    fun addListener(@Suppress("UNUSED_PARAMETER") eventName: String) {
        if (listenerCount == 0) {
            attachProgressCollector()
        }
        listenerCount += 1
    }

    fun removeListeners(count: Int) {
        listenerCount = (listenerCount - count).coerceAtLeast(0)
        if (listenerCount == 0) {
            progressJob?.cancel()
            progressJob = null
        }
    }

    private fun attachProgressCollector() {
        progressJob?.cancel()
        progressJob = moduleScope.launch {
            DVAIBridge.progressFlow.collect { event ->
                val payload = event.toJsEvent()
                emitProgressEvent(payload)
            }
        }
    }

    private fun emitProgressEvent(payload: WritableMap) {
        // Use the bridge's DeviceEventManagerModule.RCTDeviceEventEmitter to
        // dispatch events. Compatible with both old-arch and new-arch
        // (Bridgeless) RN.
        try {
            reactContext
                .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter::class.java)
                .emit("DVAIBridgeProgress", payload)
        } catch (_: Throwable) {
            // The JS context may have been torn down (e.g. fast-refresh
            // in dev). Swallow rather than crash the host app.
        }
    }

    // MARK: - Helpers

    private fun parseStartOptions(opts: ReadableMap): StartOptions {
        val backendStr = opts.getString("backend")
            ?: throw DVAIBridgeError.ConfigurationInvalid("StartOptions: missing `backend`")
        val backend = BackendKind.fromJsName(backendStr)
            ?: throw DVAIBridgeError.BackendUnavailable(
                BackendKind.Auto,
                "Backend \"$backendStr\" is not available on Android.",
            )

        val cors: CorsConfig = opts.dynamicOrNull("corsOrigin")?.let { raw ->
            when (raw) {
                is String -> if (raw == "*") CorsConfig.Wildcard else CorsConfig.Exact(raw)
                is ReadableArray -> CorsConfig.Allowlist(raw.toStringList())
                else -> CorsConfig.Wildcard
            }
        } ?: CorsConfig.Wildcard

        return StartOptions(
            backend = backend,
            modelPath = opts.getStringOrNull("modelPath"),
            tokenizerPath = opts.getStringOrNull("tokenizerPath"),
            mmprojPath = opts.getStringOrNull("mmprojPath"),
            chatTemplate = opts.getStringOrNull("chatTemplate"),
            modelId = opts.getStringOrNull("modelId"),
            gpuLayers = opts.getIntOrNull("gpuLayers") ?: 99,
            contextSize = opts.getIntOrNull("contextSize") ?: 2048,
            threads = opts.getIntOrNull("threads") ?: 4,
            embeddingMode = opts.getBooleanOrNull("embeddingMode") ?: false,
            visionEnabled = opts.getBooleanOrNull("visionEnabled") ?: false,
            temperature = opts.getDoubleOrNull("temperature")?.toFloat() ?: 0f,
            topP = opts.getDoubleOrNull("topP")?.toFloat() ?: 1f,
            topK = opts.getIntOrNull("topK") ?: 0,
            maxNewTokens = opts.getIntOrNull("maxNewTokens") ?: 512,
            httpBasePort = opts.getIntOrNull("httpBasePort") ?: 38883,
            httpMaxPortAttempts = opts.getIntOrNull("httpMaxPortAttempts") ?: 16,
            corsOrigin = cors,
        )
    }
}

// MARK: - Conversions

/** Convert a Kotlin `BackendKind` to the lowercase JS-facing name. */
internal fun BackendKind.toJsName(): String = when (this) {
    BackendKind.Auto -> "auto"
    BackendKind.Llama -> "llama"
    BackendKind.MediaPipe -> "mediapipe"
    BackendKind.LiteRT -> "litert"
}

/**
 * Look up the Kotlin `BackendKind` for a JS-side backend string. Returns
 * null for iOS-only kinds (`foundation`, `coreml`, `mlx`) — the caller
 * raises a `BackendUnavailable` error in that case so the JS side gets
 * a stable failure mode.
 */
internal fun BackendKind.Companion.fromJsName(name: String): BackendKind? = when (name) {
    "auto" -> BackendKind.Auto
    "llama" -> BackendKind.Llama
    "mediapipe" -> BackendKind.MediaPipe
    "litert" -> BackendKind.LiteRT
    else -> null
}

/**
 * Convert a Kotlin `ProgressEvent` into the JS event-emitter payload shape
 * `{ kind, phase, percent?, message?, error? }`.
 *
 * The Android `ProgressEvent.phase` is a free-form string already (matches
 * the JS-side `"start" | "stop" | "download"` discriminator), so this
 * mostly just re-shapes the field set.
 */
internal fun ProgressEvent.toJsEvent(): WritableMap = Arguments.createMap().apply {
    when (val ev = this@toJsEvent) {
        is ProgressEvent.Started -> {
            putString("kind", "started")
            putString("phase", ev.phase)
        }
        is ProgressEvent.Progress -> {
            putString("kind", "progress")
            putString("phase", ev.phase)
            // Android emits percent as 0..1 float (with -1 for indeterminate);
            // JS expects 0..100 with omission for indeterminate.
            if (ev.percent >= 0f) {
                putDouble("percent", (ev.percent * 100.0).coerceIn(0.0, 100.0))
            }
            if (ev.message.isNotEmpty()) putString("message", ev.message)
        }
        is ProgressEvent.Completed -> {
            putString("kind", "completed")
            putString("phase", ev.phase)
        }
        is ProgressEvent.Failed -> {
            putString("kind", "failed")
            putString("phase", ev.phase)
            val errMap = Arguments.createMap().apply {
                putString("kind", ev.error.toErrorKind())
                putString("message", ev.error.message ?: ev.error::class.simpleName.orEmpty())
            }
            putMap("error", errMap)
        }
    }
}

/**
 * Stable JS-side `kind` discriminator for a `DVAIBridgeError` instance.
 * Mirrors `DVAIBridgeErrorKind` in `src/types.ts`.
 */
internal fun DVAIBridgeError.toErrorKind(): String = when (this) {
    is DVAIBridgeError.AlreadyStarted -> "alreadyStarted"
    is DVAIBridgeError.ConfigurationInvalid -> "configurationInvalid"
    is DVAIBridgeError.ModelLoadFailed -> "modelLoadFailed"
    is DVAIBridgeError.BackendUnavailable -> "backendUnavailable"
    is DVAIBridgeError.BackendError -> "backendError"
    is DVAIBridgeError.ChecksumMismatch -> "checksumMismatch"
    is DVAIBridgeError.DownloadFailed -> "downloadFailed"
}

/** Reject a Promise with the canonical `DVAIBridgeError` shape. */
internal fun Promise.rejectWith(err: DVAIBridgeError) {
    val code = err.toErrorKind()
    val message = err.message ?: err::class.simpleName.orEmpty()
    val userInfo = Arguments.createMap().apply {
        putString("kind", code)
        when (err) {
            is DVAIBridgeError.AlreadyStarted -> {
                putString("currentBackend", err.currentBackend.toJsName())
                putString("baseUrl", err.baseUrl)
            }
            is DVAIBridgeError.BackendUnavailable -> {
                putString("backend", err.backend.toJsName())
            }
            else -> Unit
        }
    }
    this.reject(code, message, err, userInfo)
}

// MARK: - ReadableMap convenience

private fun ReadableMap.getStringOrNull(key: String): String? =
    if (hasKey(key) && !isNull(key)) getString(key) else null

private fun ReadableMap.getIntOrNull(key: String): Int? =
    if (hasKey(key) && !isNull(key)) getInt(key) else null

private fun ReadableMap.getBooleanOrNull(key: String): Boolean? =
    if (hasKey(key) && !isNull(key)) getBoolean(key) else null

private fun ReadableMap.getDoubleOrNull(key: String): Double? =
    if (hasKey(key) && !isNull(key)) getDouble(key) else null

/** Returns a Kotlin Any? for keys whose dynamic type isn't known up-front. */
private fun ReadableMap.dynamicOrNull(key: String): Any? {
    if (!hasKey(key) || isNull(key)) return null
    return when (getType(key)) {
        com.facebook.react.bridge.ReadableType.String -> getString(key)
        com.facebook.react.bridge.ReadableType.Array -> getArray(key)
        com.facebook.react.bridge.ReadableType.Map -> getMap(key)
        com.facebook.react.bridge.ReadableType.Boolean -> getBoolean(key)
        com.facebook.react.bridge.ReadableType.Number -> getDouble(key)
        else -> null
    }
}

private fun ReadableArray.toStringList(): List<String> {
    val out = ArrayList<String>(size())
    for (i in 0 until size()) {
        out += getString(i)
    }
    return out
}
