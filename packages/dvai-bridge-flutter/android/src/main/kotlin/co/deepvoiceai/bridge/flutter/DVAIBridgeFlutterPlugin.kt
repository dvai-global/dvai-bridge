package co.deepvoiceai.bridge.flutter

// DVAIBridgeFlutterPlugin — Kotlin entry point for the `dvai_bridge`
// Flutter plugin (Android side).
//
// Architecture mirrors the iOS plugin:
//
//   - Implements the Pigeon-generated `DVAIBridgeHostApi` interface (4
//     lifecycle methods). Each method launches a coroutine on
//     `pluginScope` to call into `co.deepvoiceai.bridge.DVAIBridge`'s
//     suspend functions, then bridges the result back into Pigeon's
//     `Result<…>` callback.
//
//   - Subscribes to `DVAIBridge.progressFlow` on first listener of the
//     Pigeon event channel and emits `ProgressEventMessage` payloads.
//     Cancels the collection job on `onCancel`.
//
//   - Translates Kotlin's sealed `DVAIBridgeError` hierarchy into
//     `FlutterError` instances whose `code` field uses the same lowercase
//     camelCase wire identifier as the Dart enum. The Dart facade decodes
//     back via `DVAIBridgeError.fromPlatform(...)`.
//
// Lifecycle: one plugin instance per `FlutterEngine`. `onAttachedToEngine`
// wires the Pigeon channels; `onDetachedFromEngine` tears them down and
// cancels the plugin scope.

import co.deepvoiceai.bridge.BackendKind
import co.deepvoiceai.bridge.BoundServer
import co.deepvoiceai.bridge.DVAIBridge
import co.deepvoiceai.bridge.DVAIBridgeError
import co.deepvoiceai.bridge.DownloadOptions
import co.deepvoiceai.bridge.ProgressEvent
import co.deepvoiceai.bridge.StartOptions
import co.deepvoiceai.bridge.StatusInfo
import co.deepvoiceai.bridge.shared.core.CorsConfig
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

class DVAIBridgeFlutterPlugin : FlutterPlugin, DVAIBridgeHostApi {

    private var pluginScope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var binaryMessenger: BinaryMessenger? = null
    private val progressStreamHandler = ProgressStreamHandler()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // Re-init defensively. Idempotent in DVAIBridge.init.
        DVAIBridge.init(binding.applicationContext)

        val messenger = binding.binaryMessenger
        binaryMessenger = messenger

        DVAIBridgeHostApi.setUp(messenger, this)
        ProgressEventsStreamHandler.register(messenger, progressStreamHandler)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        binaryMessenger?.let { messenger ->
            DVAIBridgeHostApi.setUp(messenger, null)
        }
        binaryMessenger = null
        progressStreamHandler.stopCollection()
        pluginScope.cancel()
        // Recreate so a re-attach (rare; e.g. add-to-app `FlutterEngineGroup`
        // scenarios) gets a fresh scope.
        pluginScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    }

    // MARK: - DVAIBridgeHostApi

    override fun startBridge(
        opts: StartOptionsMessage,
        callback: (Result<BoundServerMessage>) -> Unit,
    ) {
        pluginScope.launch {
            try {
                val startOptions = toStartOptions(opts)
                val server = DVAIBridge.start(startOptions)
                callback(Result.success(toMessage(server)))
            } catch (e: DVAIBridgeError) {
                callback(Result.failure(toFlutterError(e)))
            } catch (e: Throwable) {
                callback(
                    Result.failure(
                        toFlutterError(DVAIBridgeError.BackendError(e)),
                    ),
                )
            }
        }
    }

    override fun stopBridge(callback: (Result<Unit>) -> Unit) {
        pluginScope.launch {
            try {
                DVAIBridge.stop()
                callback(Result.success(Unit))
            } catch (e: DVAIBridgeError) {
                callback(Result.failure(toFlutterError(e)))
            } catch (e: Throwable) {
                callback(
                    Result.failure(
                        toFlutterError(DVAIBridgeError.BackendError(e)),
                    ),
                )
            }
        }
    }

    override fun status(callback: (Result<StatusInfoMessage>) -> Unit) {
        // status() is synchronous on Android — wrap for parity with iOS.
        try {
            val info: StatusInfo = DVAIBridge.status()
            callback(
                Result.success(
                    StatusInfoMessage(
                        running = info.running,
                        baseUrl = info.baseUrl,
                        port = null,
                        backend = info.backend?.toWire(),
                        modelId = info.modelId,
                    ),
                ),
            )
        } catch (e: Throwable) {
            callback(
                Result.failure(
                    toFlutterError(DVAIBridgeError.BackendError(e)),
                ),
            )
        }
    }

    override fun downloadModel(
        opts: DownloadOptionsMessage,
        callback: (Result<DownloadResultMessage>) -> Unit,
    ) {
        pluginScope.launch {
            try {
                val destFilename = opts.destFilename ?: deriveFilename(opts.url)
                val result = DVAIBridge.downloadModel(
                    DownloadOptions(
                        url = opts.url,
                        sha256 = opts.sha256,
                        destFilename = destFilename,
                    ),
                )
                callback(
                    Result.success(
                        DownloadResultMessage(
                            path = result.path,
                            sha256 = result.sha256,
                            sizeBytes = result.sizeBytes,
                            cached = null,
                        ),
                    ),
                )
            } catch (e: DVAIBridgeError) {
                callback(Result.failure(toFlutterError(e)))
            } catch (e: Throwable) {
                callback(
                    Result.failure(
                        toFlutterError(
                            DVAIBridgeError.DownloadFailed(
                                e.message ?: "unknown",
                                e,
                            ),
                        ),
                    ),
                )
            }
        }
    }

    private fun deriveFilename(url: String): String {
        val trimmed = url.substringBefore('?').substringBefore('#')
        return trimmed.substringAfterLast('/').ifEmpty { "model.bin" }
    }

    // MARK: - Translation helpers

    private fun toStartOptions(msg: StartOptionsMessage): StartOptions {
        val backend = backendKindFromWire(msg.backend)
            ?: throw DVAIBridgeError.ConfigurationInvalid("Unknown backend ${msg.backend}")

        val cors: CorsConfig = when (val raw = msg.corsOrigin) {
            null, "*" -> CorsConfig.Wildcard
            else -> if (raw.contains(",")) {
                CorsConfig.Allowlist(raw.split(",").map { it.trim() }.filter { it.isNotEmpty() })
            } else {
                CorsConfig.Exact(raw)
            }
        }

        return StartOptions(
            backend = backend,
            modelPath = msg.modelPath,
            tokenizerPath = msg.tokenizerPath,
            mmprojPath = msg.mmprojPath,
            chatTemplate = msg.chatTemplate,
            gpuLayers = msg.gpuLayers?.toInt() ?: 99,
            contextSize = msg.contextSize?.toInt() ?: 2048,
            threads = msg.threads?.toInt() ?: 4,
            embeddingMode = msg.embeddingMode ?: false,
            visionEnabled = msg.visionEnabled ?: false,
            temperature = msg.temperature?.toFloat() ?: 0f,
            topP = msg.topP?.toFloat() ?: 1f,
            topK = msg.topK?.toInt() ?: 0,
            maxNewTokens = msg.maxNewTokens?.toInt() ?: 512,
            httpBasePort = msg.httpBasePort?.toInt() ?: 38883,
            httpMaxPortAttempts = msg.httpMaxPortAttempts?.toInt() ?: 16,
            corsOrigin = cors,
            modelId = msg.modelId,
        )
    }

    private fun toMessage(server: BoundServer): BoundServerMessage {
        return BoundServerMessage(
            baseUrl = server.baseUrl,
            port = server.port.toLong(),
            backend = server.backend.toWire(),
            modelId = server.modelId,
        )
    }

    private fun toFlutterError(error: DVAIBridgeError): FlutterError {
        val code: String
        val details: Map<String, Any?>?
        when (error) {
            is DVAIBridgeError.AlreadyStarted -> {
                code = "alreadyStarted"
                details = mapOf(
                    "backend" to error.currentBackend.toWire(),
                    "baseUrl" to error.baseUrl,
                )
            }
            is DVAIBridgeError.ConfigurationInvalid -> {
                code = "configurationInvalid"
                details = null
            }
            is DVAIBridgeError.ModelLoadFailed -> {
                code = "modelLoadFailed"
                details = null
            }
            is DVAIBridgeError.BackendUnavailable -> {
                code = "backendUnavailable"
                details = mapOf("backend" to error.backend.toWire())
            }
            is DVAIBridgeError.BackendError -> {
                code = "backendError"
                details = null
            }
            is DVAIBridgeError.ChecksumMismatch -> {
                code = "checksumMismatch"
                // The class doesn't expose `expected` / `actual` as
                // properties post-construction; the message string carries
                // them. Pass through as a single message instead.
                details = null
            }
            is DVAIBridgeError.DownloadFailed -> {
                code = "downloadFailed"
                details = null
            }
        }
        return FlutterError(
            code = code,
            message = error.message ?: error.toString(),
            details = details,
        )
    }

    // MARK: - Progress event channel

    /// Stream handler for the Pigeon `progressEvents` event channel. Collects
    /// `DVAIBridge.progressFlow` on plugin scope and emits the
    /// `ProgressEventMessage` shape that the iOS side also produces.
    inner class ProgressStreamHandler : ProgressEventsStreamHandler() {
        private var collectionJob: Job? = null

        override fun onListen(p0: Any?, sink: PigeonEventSink<ProgressEventMessage>) {
            collectionJob?.cancel()
            collectionJob = pluginScope.launch(Dispatchers.Main.immediate) {
                DVAIBridge.progressFlow.collect { event ->
                    sink.success(toMessage(event))
                }
            }
        }

        override fun onCancel(p0: Any?) {
            collectionJob?.cancel()
            collectionJob = null
        }

        fun stopCollection() {
            collectionJob?.cancel()
            collectionJob = null
        }

        private fun toMessage(event: ProgressEvent): ProgressEventMessage {
            return when (event) {
                is ProgressEvent.Started -> ProgressEventMessage(
                    kind = "started",
                    phase = event.phase,
                )
                is ProgressEvent.Progress -> ProgressEventMessage(
                    kind = "progress",
                    phase = event.phase,
                    percent = event.percent.toDouble().takeIf { it >= 0.0 }
                        ?.let { it * 100.0 },
                    message = event.message.ifEmpty { null },
                )
                is ProgressEvent.Completed -> ProgressEventMessage(
                    kind = "completed",
                    phase = event.phase,
                )
                is ProgressEvent.Failed -> ProgressEventMessage(
                    kind = "failed",
                    phase = event.phase,
                    errorKind = event.error.toWireKind(),
                    errorMessage = event.error.message,
                )
            }
        }
    }
}

// MARK: - Wire-format helpers

private fun BackendKind.toWire(): String = when (this) {
    BackendKind.Auto -> "auto"
    BackendKind.Llama -> "llama"
    BackendKind.MediaPipe -> "mediapipe"
    BackendKind.LiteRT -> "litert"
}

private fun backendKindFromWire(value: String): BackendKind? = when (value) {
    "auto" -> BackendKind.Auto
    "llama" -> BackendKind.Llama
    "mediapipe" -> BackendKind.MediaPipe
    "litert" -> BackendKind.LiteRT
    else -> null
}

private fun DVAIBridgeError.toWireKind(): String = when (this) {
    is DVAIBridgeError.AlreadyStarted -> "alreadyStarted"
    is DVAIBridgeError.ConfigurationInvalid -> "configurationInvalid"
    is DVAIBridgeError.ModelLoadFailed -> "modelLoadFailed"
    is DVAIBridgeError.BackendUnavailable -> "backendUnavailable"
    is DVAIBridgeError.BackendError -> "backendError"
    is DVAIBridgeError.ChecksumMismatch -> "checksumMismatch"
    is DVAIBridgeError.DownloadFailed -> "downloadFailed"
}

