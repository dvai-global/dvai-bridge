package co.deepvoiceai.bridge.litert.core

import co.deepvoiceai.bridge.litert.core.Internal.HFTokenizerJson
import co.deepvoiceai.bridge.litert.core.Internal.LiteRTEngine
import co.deepvoiceai.bridge.litert.core.Internal.LiteRTGenerator
import co.deepvoiceai.bridge.litert.core.Internal.LiteRTSampler
import co.deepvoiceai.bridge.shared.core.CorsConfig
import co.deepvoiceai.bridge.shared.core.HandlerContext
import co.deepvoiceai.bridge.shared.core.HttpServer
import com.google.ai.edge.litert.Accelerator
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.random.Random

/**
 * Owns the running state of the LiteRT core: the engine, the tokenizer,
 * the HTTP server, and model metadata. All access is serialized through
 * a [Mutex] so concurrent start/stop calls can never race against the
 * underlying [com.google.ai.edge.litert.CompiledModel] (whose internal
 * KV-cache state is single-conversation by design).
 *
 * Capacitor-free: opts are plain `Map<String, Any?>` and return values
 * are plain `Map<String, Any?>`. The Capacitor wrapper translates
 * JSObject ↔ Map at the JS bridge boundary (consistent with the
 * existing llama-core / mediapipe-core PluginState shape).
 *
 * Required `start()` opts:
 *  - `modelPath`     String — absolute path to the .tflite / .litertlm file.
 *  - `tokenizerPath` String — absolute path to the HF `tokenizer.json`.
 *
 * Optional `start()` opts (all have sane defaults):
 *  - `contextSize`         Int   default 2048
 *  - `temperature`         Float default 0.0 (greedy)
 *  - `topP`                Float default 1.0
 *  - `topK`                Int   default 0 (disabled)
 *  - `maxNewTokens`        Int   default 256
 *  - `eosTokenId`          Int   override tokenizer.json's discovered EOS
 *  - `accelerator`         String "cpu" | "gpu" | "npu"   default "cpu"
 *  - `chatTemplate`        String "llama3" | "plain"     default "llama3"
 *  - `litertInputName`     String default "input_ids"
 *  - `litertCausalMaskName` String default "causal_mask"
 *  - `litertOutputName`    String default "logits"
 *  - `httpBasePort`        Int   default 38883
 *  - `httpMaxPortAttempts` Int   default 16
 *  - `corsOrigin`          (see [CorsConfig.fromOpt])
 *  - `samplerSeed`         Long  default System.nanoTime()
 *  - `modelId`             String default modelPath basename
 */
class LiteRTPluginState {
    private val mutex = Mutex()
    private var server: HttpServer? = null
    private var engine: LiteRTEngine? = null
    private var modelId: String = ""
    private var isRunning: Boolean = false
    private var baseUrl: String? = null
    private var port: Int? = null

    suspend fun start(opts: Map<String, Any?>): Map<String, Any?> = mutex.withLock {
        if (isRunning) stopInternal()

        val modelPath = (opts["modelPath"] as? String)?.takeIf { it.isNotEmpty() }
            ?: throw IllegalArgumentException("modelPath is required for litert backend")
        val tokenizerPath = (opts["tokenizerPath"] as? String)?.takeIf { it.isNotEmpty() }
            ?: throw IllegalArgumentException("tokenizerPath is required for litert backend")

        val contextSize = (opts["contextSize"] as? Number)?.toInt() ?: 2048
        val temperature = (opts["temperature"] as? Number)?.toFloat() ?: 0.0f
        val topP = (opts["topP"] as? Number)?.toFloat() ?: 1.0f
        val topK = (opts["topK"] as? Number)?.toInt() ?: 0
        val maxNewTokens = (opts["maxNewTokens"] as? Number)?.toInt() ?: 256
        val eosOverride = (opts["eosTokenId"] as? Number)?.toInt()
        val acceleratorOpt = (opts["accelerator"] as? String)?.lowercase()
        val accelerator = when (acceleratorOpt) {
            "gpu" -> Accelerator.GPU
            "npu" -> Accelerator.NPU
            null, "cpu" -> Accelerator.CPU
            else -> throw IllegalArgumentException("invalid 'accelerator' opt: $acceleratorOpt (expected cpu|gpu|npu)")
        }
        val chatTemplateOpt = (opts["chatTemplate"] as? String)?.lowercase()
        val chatTemplate = when (chatTemplateOpt) {
            null, "llama3" -> ChatTemplateRenderer.LLAMA3
            "plain" -> ChatTemplateRenderer.PLAIN
            else -> throw IllegalArgumentException("invalid 'chatTemplate' opt: $chatTemplateOpt (expected llama3|plain)")
        }
        val inputName = (opts["litertInputName"] as? String) ?: "input_ids"
        val causalMaskName = (opts["litertCausalMaskName"] as? String) ?: "causal_mask"
        val outputName = (opts["litertOutputName"] as? String) ?: "logits"
        val httpBasePort = (opts["httpBasePort"] as? Number)?.toInt() ?: 38883
        val httpMaxPortAttempts = (opts["httpMaxPortAttempts"] as? Number)?.toInt() ?: 16
        val corsConfig = CorsConfig.fromOpt(opts["corsOrigin"])
        val samplerSeed = (opts["samplerSeed"] as? Number)?.toLong() ?: System.nanoTime()
        val resolvedModelId = (opts["modelId"] as? String)?.takeIf { it.isNotEmpty() }
            ?: deriveModelId(modelPath)

        // Load tokenizer FIRST so we can pick up its discovered EOS for the
        // engine constructor. Tokenizer load failure is cheap; engine load
        // is expensive (loads the full .tflite into memory).
        val tokenizer = try {
            HFTokenizerJson.load(tokenizerPath, eosTokenIdOverride = eosOverride)
        } catch (e: LiteRTBackendError.TokenizerLoadFailed) {
            throw e
        }

        val newEngine = try {
            LiteRTEngine(
                modelPath = modelPath,
                inputName = inputName,
                causalMaskName = causalMaskName,
                outputName = outputName,
                contextSize = contextSize,
                eosTokenId = tokenizer.eosTokenId,
                accelerator = accelerator,
            )
        } catch (e: LiteRTBackendError.ModelLoadFailed) {
            throw e
        }

        val sampler = LiteRTSampler(
            temperature = temperature,
            topP = topP,
            topK = topK,
            random = Random(samplerSeed),
        )
        val generator = LiteRTGenerator(
            engine = newEngine,
            tokenizer = tokenizer,
            sampler = sampler,
            maxNewTokens = maxNewTokens,
        )
        val handlers = LiteRTHandlers(
            generator = generator,
            modelId = resolvedModelId,
            chatTemplate = chatTemplate,
            maxNewTokensDefault = maxNewTokens,
        )
        val ctx = HandlerContext(modelId = resolvedModelId, backendName = "litert")

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
            // Bind failed — release the engine we already initialized so we
            // don't leak the native handle.
            runCatching { newEngine.close() }
            throw t
        }

        this.engine = newEngine
        this.server = newServer
        this.modelId = resolvedModelId
        this.port = boundPort
        this.baseUrl = "http://127.0.0.1:$boundPort/v1"
        this.isRunning = true

        return@withLock mapOf(
            "baseUrl" to "http://127.0.0.1:$boundPort/v1",
            "port" to boundPort,
            "backend" to "litert",
            "modelId" to resolvedModelId,
        )
    }

    suspend fun stop() = mutex.withLock { stopInternal() }

    private suspend fun stopInternal() {
        server?.stop()
        runCatching { engine?.close() }
        server = null
        engine = null
        modelId = ""
        baseUrl = null
        port = null
        isRunning = false
    }

    fun statusInfo(): Map<String, Any?> = buildMap {
        put("running", isRunning)
        baseUrl?.let { put("baseUrl", it) }
        if (isRunning) put("backend", "litert")
    }

    /**
     * Best-effort default model id from a model file path: strip the
     * directory prefix and any `.tflite` / `.litertlm` extension.
     * Mirrors `MediaPipePluginState.deriveModelId`.
     */
    private fun deriveModelId(modelPath: String): String {
        val name = modelPath.substringAfterLast('/').substringAfterLast('\\')
        val stripped = name.removeSuffix(".tflite").removeSuffix(".litertlm")
        return stripped.ifEmpty { "litert-default" }
    }
}
