package co.deepvoiceai.dvaibridge.mediapipe

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import java.util.UUID

/**
 * OpenAI-compatible handler set for the MediaPipe LLM backend on Android.
 * Wires `openAIMessagesToPrompt` -> `bridge.completePrompt` (sync) or
 * `bridge.completePromptAsync` (streaming) -> OpenAI response shape.
 *
 * Phase 1 scope (Task 45): text-only. Image (`image_url`) parts are rejected
 * with a 400 pointing at Task 46 where vision lands. Audio (`input_audio`) is
 * permanently rejected — MediaPipe `tasks-genai` has no audio path.
 *
 * Streaming: emitted as the standard 4-frame envelope (role / content* /
 * finish / `[DONE]`). MediaPipe's `generateResponseAsync` may invoke its
 * progress callback multiple times — each callback emits one content delta.
 * Server-side buffering in [HandlerDispatch] still collects everything before
 * flush in Phase 1, so clients see all frames together; per-token streaming
 * lands when dispatch grows a flush-per-chunk path.
 *
 * All bridge-touching paths are serialized via [bridgeMutex] because
 * `LlmInferenceSession` is not safe to use from multiple concurrent callers.
 */
class MediaPipeHandlers(
    private val bridge: MediaPipeBridgeApi,
    private val modelId: String,
) : DvaiHandlers {
    private val bridgeMutex = Mutex()

    override suspend fun handleChatCompletion(body: JsonObject, ctx: HandlerContext): HandlerResponse {
        val messages = body["messages"] as? JsonArray
            ?: return HandlerResponse.Error(400, "Missing 'messages' field")

        // Reject image / audio content parts up-front, before building the prompt.
        // (Mirrors LlamaHandlers/FoundationHandlers ordering.)
        for (msg in messages) {
            val msgObj = msg as? JsonObject ?: continue
            val content = msgObj["content"] as? JsonArray ?: continue
            for (part in content) {
                val partObj = part as? JsonObject ?: continue
                val type = (partObj["type"] as? JsonPrimitive)?.contentOrNull
                if (type == "image_url") {
                    return HandlerResponse.Error(
                        400,
                        "Image input not yet supported on MediaPipe LLM in Phase 1 " +
                            "(lands in Task 46). Request had image_url part.",
                    )
                }
                if (type == "input_audio") {
                    return HandlerResponse.Error(
                        400,
                        "Audio input not supported on MediaPipe LLM " +
                            "(no audio-capable tasks-genai task).",
                    )
                }
            }
        }

        if (messages.isEmpty()) {
            return HandlerResponse.Error(400, "Empty 'messages' array")
        }

        val prompt = openAIMessagesToPrompt(messages)
        val isStream = (body["stream"] as? JsonPrimitive)?.booleanOrNull ?: false

        val id = "chatcmpl-mp-" + UUID.randomUUID().toString().take(20).lowercase()
        val created = System.currentTimeMillis() / 1000L

        if (isStream) {
            return HandlerResponse.Sse(buildChatStreamFrames(id = id, created = created, prompt = prompt))
        }

        val text = try {
            bridgeMutex.withLock {
                withContext(Dispatchers.IO) { bridge.completePrompt(prompt) }
            }
        } catch (e: Exception) {
            return HandlerResponse.Error(500, e.message ?: "Inference failed")
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
                        put("content", text)
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

    override suspend fun handleEmbeddings(body: JsonObject, ctx: HandlerContext): HandlerResponse =
        HandlerResponse.Error(
            400,
            "Embeddings not supported on MediaPipe LLM. " +
                "Use capacitorBackend: \"llama\" with nativeEmbeddingMode: true.",
        )

    override suspend fun handleModels(ctx: HandlerContext): HandlerResponse =
        HandlerResponse.Json(
            200,
            buildJsonObject {
                put("object", "list")
                putJsonArray("data") {
                    addJsonObject {
                        put("id", ctx.modelId)
                        put("object", "model")
                        put("owned_by", "google-mediapipe")
                    }
                }
            },
        )

    // ----- Streaming -----

    /**
     * Build the SSE 4-frame envelope (role / content* / finish / [DONE]).
     *
     * Acquires [bridgeMutex] for the lifetime of the stream and releases it
     * in [awaitClose] — guarantees serialization with non-streaming requests
     * AND mutex release on either successful completion or coroutine
     * cancellation.
     */
    private fun buildChatStreamFrames(id: String, created: Long, prompt: String): Flow<String> = callbackFlow {
        // Serialize against any other bridge use for the entire stream lifetime.
        bridgeMutex.lock()

        // Frame 0: role chunk
        val roleChunk = buildJsonObject {
            put("id", id); put("object", "chat.completion.chunk")
            put("created", created); put("model", modelId)
            putJsonArray("choices") {
                addJsonObject {
                    put("index", 0)
                    putJsonObject("delta") { put("role", "assistant") }
                }
            }
        }
        trySend("data: $roleChunk\n\n")

        val handle: AutoCloseable = try {
            bridge.completePromptAsync(prompt) { partial, done ->
                // Content-delta chunk for every (partial, done) pair. When `done`
                // is true the final frame carries finish_reason="stop"; otherwise
                // finish_reason is null.
                val chunk = buildJsonObject {
                    put("id", id); put("object", "chat.completion.chunk")
                    put("created", created); put("model", modelId)
                    putJsonArray("choices") {
                        addJsonObject {
                            put("index", 0)
                            putJsonObject("delta") { put("content", partial) }
                            if (done) {
                                put("finish_reason", "stop")
                            } else {
                                put("finish_reason", JsonNull)
                            }
                        }
                    }
                }
                trySend("data: $chunk\n\n")
                if (done) {
                    trySend("data: [DONE]\n\n")
                    close()
                }
            }
        } catch (e: Exception) {
            // Generation failed to start. Emit an error chunk + [DONE] so the
            // client sees a well-formed SSE close, then complete the flow with
            // the exception (collector receives it).
            val errChunk = buildJsonObject {
                put("id", id); put("object", "chat.completion.chunk")
                put("created", created); put("model", modelId)
                putJsonArray("choices") {
                    addJsonObject {
                        put("index", 0)
                        putJsonObject("delta") { /* empty */ }
                        put("finish_reason", "error")
                    }
                }
                putJsonObject("error") { put("message", e.message ?: "Inference failed") }
            }
            trySend("data: $errChunk\n\n")
            trySend("data: [DONE]\n\n")
            close(e)
            // Release the mutex synchronously — awaitClose still runs but
            // there is no AutoCloseable handle to call close() on.
            if (bridgeMutex.isLocked) bridgeMutex.unlock()
            return@callbackFlow
        }

        awaitClose {
            try {
                handle.close()
            } catch (_: Throwable) { /* best-effort */ }
            if (bridgeMutex.isLocked) bridgeMutex.unlock()
        }
    }

    // ----- Helpers -----

    /**
     * Flatten OpenAI chat messages into a single `role: content` newline-joined
     * prompt string. Multimodal content arrays are reduced to their `text`
     * parts (image / audio parts are rejected before this method is reached).
     */
    private fun openAIMessagesToPrompt(messages: JsonArray): String =
        messages.mapNotNull { msg ->
            val msgObj = msg as? JsonObject ?: return@mapNotNull null
            val role = (msgObj["role"] as? JsonPrimitive)?.contentOrNull ?: "user"
            val content = msgObj["content"]
            when (content) {
                is JsonPrimitive -> "$role: ${content.contentOrNull ?: ""}"
                is JsonArray -> {
                    val texts = content.mapNotNull inner@{ part ->
                        val partObj = part as? JsonObject ?: return@inner null
                        if ((partObj["type"] as? JsonPrimitive)?.contentOrNull == "text") {
                            (partObj["text"] as? JsonPrimitive)?.contentOrNull
                        } else {
                            null
                        }
                    }
                    if (texts.isNotEmpty()) "$role: ${texts.joinToString(" ")}" else null
                }
                else -> null
            }
        }.joinToString("\n")

    /** Mirrors `chatToLegacyCompletion()` from `packages/dvai-bridge-core`. */
    private fun chatToLegacyCompletion(chat: JsonObject): JsonObject = buildJsonObject {
        val chatId = (chat["id"] as? JsonPrimitive)?.contentOrNull ?: ""
        val cmplId = if (chatId.isEmpty()) {
            "cmpl-${System.currentTimeMillis() / 1000L}"
        } else {
            chatId.replace("chatcmpl-", "cmpl-")
        }
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
            Json.parseToJsonElement(payload) as? JsonObject ?: return chunk
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
}
