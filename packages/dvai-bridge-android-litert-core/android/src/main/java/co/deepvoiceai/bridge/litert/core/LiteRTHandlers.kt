package co.deepvoiceai.bridge.litert.core

import co.deepvoiceai.bridge.litert.core.Internal.LiteRTGenerator
import co.deepvoiceai.bridge.shared.core.DvaiHandlers
import co.deepvoiceai.bridge.shared.core.HandlerContext
import co.deepvoiceai.bridge.shared.core.HandlerResponse
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

/**
 * OpenAI-compatible handler set for the LiteRT backend.
 *
 * Wires [LiteRTGenerator] into the four standard routes:
 *   POST /v1/chat/completions → tokenize messages, generate, wrap.
 *   POST /v1/completions      → adapt chat output to the legacy text shape.
 *   POST /v1/embeddings       → 501 Not Implemented (LiteRT raw graphs
 *                                don't expose an embedding head).
 *   GET  /v1/models           → standard list-with-one-item shape.
 *
 * Streaming for chat: same 4-frame shape (role / content / finish / [DONE])
 * as `LlamaHandlers` — Ktor's responseChannel buffers the body anyway, so
 * 4-chunk vs 1-chunk is identical to the client. Real per-token streaming
 * lands when the dispatch layer flushes per chunk (out of scope here).
 *
 * Chat-template rendering: the LiteRT backend ships a hard-coded Llama-3
 * template (`<|begin_of_text|><|start_header_id|>{role}<|end_header_id|>\n\n{content}<|eot_id|>`).
 * Most Llama-3.x family checkpoints accept it. Non-Llama checkpoints
 * require the consumer to pre-render the prompt themselves and send a
 * single user message — see the consumer guide.
 *
 * All generator-touching paths are serialized via [generatorMutex] because
 * the underlying LiteRT [com.google.ai.edge.litert.CompiledModel] keeps
 * an internal KV-cache state across calls; concurrent requests would
 * interleave tokens from different conversations.
 */
class LiteRTHandlers internal constructor(
    private val generator: LiteRTGenerator,
    private val modelId: String,
    /** Extra opt to override the default Llama-3 chat-template renderer. */
    private val chatTemplate: ChatTemplateRenderer = ChatTemplateRenderer.LLAMA3,
    private val maxNewTokensDefault: Int = 256,
) : DvaiHandlers {

    private val generatorMutex = Mutex()

    override suspend fun handleChatCompletion(body: JsonObject, ctx: HandlerContext): HandlerResponse {
        val messagesJson = body["messages"] as? JsonArray
            ?: return HandlerResponse.Error(400, "Missing 'messages' field")
        val messages = mutableListOf<Pair<String, String>>()
        for (m in messagesJson) {
            val obj = m as? JsonObject
                ?: return HandlerResponse.Error(400, "messages entry is not an object")
            val role = (obj["role"] as? JsonPrimitive)?.contentOrNull
                ?: return HandlerResponse.Error(400, "messages entry missing 'role'")
            // Only string `content` is accepted in the LiteRT backend —
            // multimodal content parts (image_url / input_audio) are not
            // routable through bare LiteRT graphs (no mmproj equivalent).
            val content = (obj["content"] as? JsonPrimitive)?.contentOrNull
                ?: return HandlerResponse.Error(
                    400,
                    "LiteRT backend only accepts string `content` (not multimodal arrays)",
                )
            messages.add(role to content)
        }

        val prompt = chatTemplate.render(messages)

        val stream = (body["stream"] as? JsonPrimitive)?.booleanOrNull ?: false
        @Suppress("UNUSED_VARIABLE") // kept for future per-call sampler overrides
        val maxTokens = (body["max_tokens"] as? JsonPrimitive)?.intOrNull ?: maxNewTokensDefault

        val completion: String = try {
            generatorMutex.withLock { generator.generate(prompt) }
        } catch (e: LiteRTBackendError.GenerationFailed) {
            return HandlerResponse.Error(500, e.message ?: "generation failed")
        } catch (e: Throwable) {
            return HandlerResponse.Error(500, "unexpected error: ${e.message ?: e::class.java.simpleName}")
        }

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
                // Kotlin can't smart-cast `chatResp.body` to JsonObject because
                // HandlerResponse lives in shared-core (different module) — its
                // public `val body` could in principle be a custom getter. Bind
                // to a local val and cast once. (Same pattern as LlamaHandlers.)
                val respBody = chatResp.body
                if (chatResp.status != 200 || respBody !is JsonObject) {
                    chatResp
                } else {
                    HandlerResponse.Json(200, chatToLegacyCompletion(respBody))
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
        // LiteRT raw .tflite graphs don't expose a native embedding head —
        // the consumer-facing model is purely a logits-producing language
        // model. Surfacing this as 501 Not Implemented matches the
        // OpenAI-compatible "this server doesn't support that endpoint"
        // shape; consumers wanting embeddings should use the llama
        // backend with `embeddingMode: true`.
        return HandlerResponse.Error(501, "embeddings not supported by LiteRT backend")
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

    /**
     * 4 SSE frames: role / content / finish / [DONE]. Same shape as
     * `LlamaHandlers` and `FoundationHandlers` — see the comparison in
     * `docs/development/handler-parity.md`.
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

    /** Mirrors `chatToLegacyCompletion()` from `LlamaHandlers.kt` 1:1. */
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
}

/**
 * Stringifier for OpenAI-style messages. The LiteRT backend has no Jinja
 * engine, so we ship a couple of well-known templates as Kotlin code and
 * let the consumer pick. Defaults to LLAMA3 — the dominant tokenizer
 * family on Maven Central LiteRT checkpoints in 2026.
 */
public enum class ChatTemplateRenderer {
    LLAMA3 {
        override fun render(messages: List<Pair<String, String>>): String {
            val sb = StringBuilder()
            sb.append("<|begin_of_text|>")
            for ((role, content) in messages) {
                sb.append("<|start_header_id|>").append(role).append("<|end_header_id|>\n\n")
                sb.append(content).append("<|eot_id|>")
            }
            sb.append("<|start_header_id|>assistant<|end_header_id|>\n\n")
            return sb.toString()
        }
    },

    /**
     * Dumb concatenation — appends each message as `role: content\n` and
     * a trailing `assistant:`. For checkpoints with no chat template at
     * all (raw text-completion .tflite files), or when the consumer
     * already pre-rendered the prompt and sends a single user message.
     */
    PLAIN {
        override fun render(messages: List<Pair<String, String>>): String {
            val sb = StringBuilder()
            for ((role, content) in messages) sb.append(role).append(": ").append(content).append("\n")
            sb.append("assistant: ")
            return sb.toString()
        }
    };

    abstract fun render(messages: List<Pair<String, String>>): String
}
