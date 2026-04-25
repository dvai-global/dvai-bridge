package co.deepvoiceai.dvaibridge.llama

import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

/**
 * OpenAI-compatible handler set for the llama backend on Android. Wires
 * `ContentPartsTranslator` -> `bridge.completePrompt` -> OpenAI response shape
 * per spec section 6 + 8.
 *
 * Phase 1 scope (all `false` until Phase 2 lands the corresponding loaders):
 *  - [mmprojLoaded]: true once a multimodal projector is loaded; gates image parts.
 *  - [modelHasAudioEncoder]: true once a model with native audio is loaded; gates audio parts.
 *  - [embeddingMode]: mirrored from the start opts; gates POST /v1/embeddings.
 *
 * Streaming: SSE chunks are emitted in 4 frames (role / content / finish /
 * `[DONE]`). Ktor's testApplication buffers the body anyway, so 4-chunk vs
 * 1-chunk is identical to the client. Real per-token streaming lands when the
 * dispatch layer flushes per chunk.
 *
 * All bridge-touching paths are serialized via [bridgeMutex] because
 * llama.cpp's `llama_context` is not thread-safe; concurrent requests would
 * corrupt the shared KV cache.
 */
class LlamaHandlers(
    private val bridge: LlamaCppBridgeApi,
    private val modelId: String,
    private val mmprojLoaded: Boolean = false,
    private val modelHasAudioEncoder: Boolean = false,
    private val embeddingMode: Boolean = false,
) : DvaiHandlers {
    private val translator = ContentPartsTranslator(
        mmprojLoaded = mmprojLoaded,
        modelHasAudioEncoder = modelHasAudioEncoder,
    )
    private val bridgeMutex = Mutex()

    override suspend fun handleChatCompletion(body: JsonObject, ctx: HandlerContext): HandlerResponse {
        val messagesJson = body["messages"] as? JsonArray
            ?: return HandlerResponse.Error(400, "Missing 'messages' field")
        val messages = messagesJson.map { jsonElementToMap(it) ?: return HandlerResponse.Error(400, "messages entry is not an object") }

        val promptInput = try {
            translator.translate(messages)
        } catch (e: TranslatorError) {
            return HandlerResponse.Error(translatorErrorToStatus(e), translatorErrorMessage(e))
        }

        if (promptInput.images.isNotEmpty() || promptInput.audioPCM.isNotEmpty()) {
            return HandlerResponse.Error(500, "Multimodal eval path not yet wired")
        }

        // TODO(strict-mode): currently silently defaults if max_tokens/temperature/top_p
        // arrive as strings instead of numbers; OpenAI rejects this with 400.
        val maxTokens = (body["max_tokens"] as? JsonPrimitive)?.intOrNull ?: 256
        val temperature = (body["temperature"] as? JsonPrimitive)?.doubleOrNull?.toFloat() ?: 1.0f
        val topP = (body["top_p"] as? JsonPrimitive)?.doubleOrNull?.toFloat() ?: 1.0f
        val stream = (body["stream"] as? JsonPrimitive)?.booleanOrNull ?: false

        val completion = bridgeMutex.withLock {
            bridge.completePrompt(promptInput.prompt, maxTokens, temperature, topP)
        } ?: return HandlerResponse.Error(500, "Completion failed (bridge returned null)")

        val id = "chatcmpl-" + java.util.UUID.randomUUID().toString().take(24).lowercase()
        val created = System.currentTimeMillis() / 1000L

        if (stream) {
            val frames = buildChatStreamFrames(id = id, created = created, completion = completion)
            return HandlerResponse.Sse(
                flow {
                    for (frame in frames) emit(frame)
                },
            )
        }

        val response = buildJsonObject {
            put("id", id)
            put("object", "chat.completion")
            put("created", created)
            put("model", modelId)
            putJsonArray("choices") {
                addJsonObject {
                    put("index", 0)
                    putJsonObject("message") {
                        put("role", "assistant")
                        put("content", completion)
                    }
                    put("finish_reason", "stop")
                }
            }
            putJsonObject("usage") {
                put("prompt_tokens", 0)
                put("completion_tokens", 0)
                put("total_tokens", 0)
            }
        }
        return HandlerResponse.Json(200, response)
    }

    override suspend fun handleCompletion(body: JsonObject, ctx: HandlerContext): HandlerResponse {
        val promptField = body["prompt"]
        val prompt: String = when {
            promptField == null || promptField is JsonNull -> ""
            promptField is JsonPrimitive && promptField.contentOrNull != null -> promptField.content
            promptField is JsonArray -> promptField.joinToString("\n") {
                (it as? JsonPrimitive)?.contentOrNull ?: ""
            }
            else -> return HandlerResponse.Error(400, "'prompt' must be a string or array of strings")
        }

        val chatBody = buildJsonObject {
            for ((k, v) in body) {
                if (k == "prompt") continue
                put(k, v)
            }
            putJsonArray("messages") {
                addJsonObject {
                    put("role", "user")
                    put("content", prompt)
                }
            }
        }

        val chatResp = handleChatCompletion(chatBody, ctx)
        return when (chatResp) {
            is HandlerResponse.Json -> {
                if (chatResp.status != 200 || chatResp.body !is JsonObject) {
                    chatResp
                } else {
                    HandlerResponse.Json(200, chatToLegacyCompletion(chatResp.body))
                }
            }
            is HandlerResponse.Sse -> {
                val model = (body["model"] as? JsonPrimitive)?.contentOrNull ?: modelId
                HandlerResponse.Sse(
                    flow {
                        chatResp.flow.collect { chunk ->
                            emit(adaptChunkToLegacy(chunk, model))
                        }
                    },
                )
            }
            is HandlerResponse.Error -> chatResp
        }
    }

    override suspend fun handleEmbeddings(body: JsonObject, ctx: HandlerContext): HandlerResponse {
        if (!embeddingMode) {
            return HandlerResponse.Error(400, "Embeddings require nativeEmbeddingMode: true at start time.")
        }
        val inputAny = body["input"]
        val inputs: List<String> = when (inputAny) {
            is JsonPrimitive -> {
                val s = inputAny.contentOrNull
                    ?: return HandlerResponse.Error(400, "Missing or malformed 'input' field")
                listOf(s)
            }
            is JsonArray -> inputAny.map {
                (it as? JsonPrimitive)?.contentOrNull
                    ?: return HandlerResponse.Error(400, "'input' array must contain strings")
            }
            else -> return HandlerResponse.Error(400, "Missing or malformed 'input' field")
        }

        val data = buildJsonArray {
            for ((i, text) in inputs.withIndex()) {
                val vec = bridgeMutex.withLock { bridge.embedding(text) }
                    ?: return HandlerResponse.Error(500, "Embedding failed (bridge returned null)")
                addJsonObject {
                    put("object", "embedding")
                    putJsonArray("embedding") {
                        for (f in vec) add(f.toDouble())
                    }
                    put("index", i)
                }
            }
        }

        val response = buildJsonObject {
            put("object", "list")
            put("data", data)
            put("model", modelId)
            putJsonObject("usage") {
                put("prompt_tokens", 0)
                put("total_tokens", 0)
            }
        }
        return HandlerResponse.Json(200, response)
    }

    override suspend fun handleModels(ctx: HandlerContext): HandlerResponse =
        HandlerResponse.Json(
            200,
            buildJsonObject {
                put("object", "list")
                putJsonArray("data") {
                    addJsonObject {
                        put("id", ctx.modelId)
                        put("object", "model")
                        put("owned_by", "dvai-bridge")
                    }
                }
            },
        )

    // ----- helpers -----

    private fun translatorErrorToStatus(e: TranslatorError): Int = when (e) {
        is TranslatorError.ImageFetchFailed -> 502
        else -> 400
    }

    private fun translatorErrorMessage(e: TranslatorError): String = e.message ?: "translator error"

    // Server-side buffering: Ktor's responseChannel for SSE buffers fully before flush
    // in our current setup; 4-chunk vs single-chunk emission is identical to clients.
    /**
     * Build the 4 SSE frames for a streaming chat.completion response: role /
     * content / finish / [DONE]. Each entry is a complete `data: <json>\n\n`
     * (or `data: [DONE]\n\n`) frame.
     */
    private fun buildChatStreamFrames(id: String, created: Long, completion: String): List<String> {
        val out = mutableListOf<String>()
        val role = buildJsonObject {
            put("id", id)
            put("object", "chat.completion.chunk")
            put("created", created)
            put("model", modelId)
            putJsonArray("choices") {
                addJsonObject {
                    put("index", 0)
                    putJsonObject("delta") { put("role", "assistant") }
                }
            }
        }
        out += "data: $role\n\n"

        val content = buildJsonObject {
            put("id", id)
            put("object", "chat.completion.chunk")
            put("created", created)
            put("model", modelId)
            putJsonArray("choices") {
                addJsonObject {
                    put("index", 0)
                    putJsonObject("delta") { put("content", completion) }
                }
            }
        }
        out += "data: $content\n\n"

        val finish = buildJsonObject {
            put("id", id)
            put("object", "chat.completion.chunk")
            put("created", created)
            put("model", modelId)
            putJsonArray("choices") {
                addJsonObject {
                    put("index", 0)
                    putJsonObject("delta") { /* empty */ }
                    put("finish_reason", "stop")
                }
            }
        }
        out += "data: $finish\n\n"

        out += "data: [DONE]\n\n"
        return out
    }

    /** Mirrors `chatToLegacyCompletion()` from `packages/dvai-bridge-core`. */
    private fun chatToLegacyCompletion(chat: JsonObject): JsonObject = buildJsonObject {
        val chatId = (chat["id"] as? JsonPrimitive)?.contentOrNull ?: ""
        val cmplId = if (chatId.isEmpty()) "cmpl-${System.currentTimeMillis() / 1000L}"
                     else chatId.replace("chatcmpl-", "cmpl-")
        put("id", cmplId)
        put("object", "text_completion")
        chat["created"]?.let { put("created", it) }
            ?: put("created", System.currentTimeMillis() / 1000L)
        put("model", (chat["model"] as? JsonPrimitive)?.contentOrNull ?: modelId)
        putJsonArray("choices") {
            val chatChoices = chat["choices"] as? JsonArray ?: JsonArray(emptyList())
            for (c in chatChoices) {
                val co = c as? JsonObject ?: continue
                addJsonObject {
                    val msg = co["message"] as? JsonObject
                    put("text", (msg?.get("content") as? JsonPrimitive)?.contentOrNull ?: "")
                    put("index", (co["index"] as? JsonPrimitive)?.intOrNull ?: 0)
                    put(
                        "finish_reason",
                        (co["finish_reason"] as? JsonPrimitive)?.contentOrNull ?: "stop",
                    )
                    put("logprobs", JsonNull)
                }
            }
        }
        val usage = chat["usage"] as? JsonObject
        if (usage != null) {
            put("usage", usage)
        } else {
            putJsonObject("usage") {
                put("prompt_tokens", 0)
                put("completion_tokens", 0)
                put("total_tokens", 0)
            }
        }
    }

    /** Adapt a single SSE frame from chat.completion.chunk -> text_completion.chunk. */
    private fun adaptChunkToLegacy(chunk: String, model: String): String {
        val trimmed = chunk.trim()
        if (!trimmed.startsWith("data:")) return chunk
        val payload = trimmed.removePrefix("data:").trim()
        if (payload == "[DONE]") return "data: [DONE]\n\n"
        val parsed = try {
            kotlinx.serialization.json.Json.parseToJsonElement(payload) as? JsonObject ?: return chunk
        } catch (_: Exception) {
            return chunk
        }
        val chatId = (parsed["id"] as? JsonPrimitive)?.contentOrNull ?: ""
        val id = chatId.replace("chatcmpl-", "cmpl-")
        val legacy = buildJsonObject {
            put("id", id)
            put("object", "text_completion.chunk")
            parsed["created"]?.let { put("created", it) }
                ?: put("created", System.currentTimeMillis() / 1000L)
            put("model", (parsed["model"] as? JsonPrimitive)?.contentOrNull ?: model)
            putJsonArray("choices") {
                val chatChoices = parsed["choices"] as? JsonArray ?: JsonArray(emptyList())
                for (c in chatChoices) {
                    val co = c as? JsonObject ?: continue
                    addJsonObject {
                        val delta = co["delta"] as? JsonObject
                        put("text", (delta?.get("content") as? JsonPrimitive)?.contentOrNull ?: "")
                        put("index", (co["index"] as? JsonPrimitive)?.intOrNull ?: 0)
                        val fr = co["finish_reason"]
                        if (fr is JsonPrimitive && fr.contentOrNull != null) {
                            put("finish_reason", fr.content)
                        } else {
                            put("finish_reason", JsonNull)
                        }
                        put("logprobs", JsonNull)
                    }
                }
            }
        }
        return "data: $legacy\n\n"
    }

    /**
     * Recursively convert a [JsonElement] into the loose `Map<String, Any?>` /
     * `List<Any?>` shape the [ContentPartsTranslator] expects. Returns null
     * if the element isn't a JsonObject (used to validate messages-array
     * entries are objects).
     */
    private fun jsonElementToMap(e: JsonElement): Map<String, Any?>? {
        if (e !is JsonObject) return null
        return convertObject(e)
    }

    private fun convertObject(o: JsonObject): Map<String, Any?> =
        o.mapValues { (_, v) -> convert(v) }

    private fun convert(e: JsonElement): Any? = when (e) {
        is JsonNull -> null
        is JsonPrimitive -> when {
            e.isString -> e.content
            else -> e.booleanOrNull ?: e.intOrNull ?: e.doubleOrNull ?: e.contentOrNull
        }
        is JsonObject -> convertObject(e)
        is JsonArray -> e.map { convert(it) }
    }
}
