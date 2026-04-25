package co.deepvoiceai.dvaibridge.llama

import kotlinx.serialization.json.*

/**
 * Stub implementation of the OpenAI-compatible handler set for the llama backend.
 * Real inference paths land in Task 36; for now, /v1/models returns a canned
 * response and the other endpoints return 501.
 */
class LlamaHandlers(
    @Suppress("unused") private val bridge: LlamaCppBridge,
    @Suppress("unused") private val modelId: String,
) : DvaiHandlers {

    override suspend fun handleChatCompletion(body: JsonObject, ctx: HandlerContext): HandlerResponse =
        HandlerResponse.Json(501, buildJsonObject { put("error", "Not implemented yet -- Task 36") })

    override suspend fun handleCompletion(body: JsonObject, ctx: HandlerContext): HandlerResponse =
        HandlerResponse.Json(501, buildJsonObject { put("error", "Not implemented yet -- Task 36") })

    override suspend fun handleEmbeddings(body: JsonObject, ctx: HandlerContext): HandlerResponse =
        HandlerResponse.Json(501, buildJsonObject { put("error", "Not implemented yet -- Task 36") })

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
}
