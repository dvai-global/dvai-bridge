package co.deepvoiceai.bridge.shared.core

import kotlinx.serialization.json.JsonObject

/**
 * The handler-set contract every backend implements. The 4 methods map
 * 1:1 to the OpenAI-compatible HTTP routes installed by
 * [Routing.installDispatchRoutes][installDispatchRoutes]:
 *
 *   POST /v1/chat/completions  -> [handleChatCompletion]
 *   POST /v1/completions       -> [handleCompletion]
 *   POST /v1/embeddings        -> [handleEmbeddings]
 *   GET  /v1/models            -> [handleModels]
 */
interface DvaiHandlers {
    suspend fun handleChatCompletion(body: JsonObject, ctx: HandlerContext): HandlerResponse
    suspend fun handleCompletion(body: JsonObject, ctx: HandlerContext): HandlerResponse
    suspend fun handleEmbeddings(body: JsonObject, ctx: HandlerContext): HandlerResponse
    suspend fun handleModels(ctx: HandlerContext): HandlerResponse
}
