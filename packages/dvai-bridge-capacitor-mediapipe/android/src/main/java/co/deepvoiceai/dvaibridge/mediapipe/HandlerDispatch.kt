package co.deepvoiceai.dvaibridge.mediapipe

import io.ktor.http.*
import io.ktor.server.application.*
import io.ktor.server.request.*
import io.ktor.server.response.*
import io.ktor.server.routing.*
import kotlinx.coroutines.flow.Flow
import kotlinx.serialization.json.*

/** Per-request context passed to every handler method. */
data class HandlerContext(val modelId: String, val backendName: String)

/** What handlers return. */
sealed class HandlerResponse {
    data class Json(val status: Int, val body: JsonElement) : HandlerResponse()
    data class Sse(val flow: Flow<String>) : HandlerResponse()
    data class Error(val status: Int, val message: String) : HandlerResponse()
}

/** Contract for the handler set. */
interface DvaiHandlers {
    suspend fun handleChatCompletion(body: JsonObject, ctx: HandlerContext): HandlerResponse
    suspend fun handleCompletion(body: JsonObject, ctx: HandlerContext): HandlerResponse
    suspend fun handleEmbeddings(body: JsonObject, ctx: HandlerContext): HandlerResponse
    suspend fun handleModels(ctx: HandlerContext): HandlerResponse
}

/** CORS configuration for the dispatch layer. */
sealed class CorsConfig {
    object Wildcard : CorsConfig()
    data class Exact(val origin: String) : CorsConfig()
    data class Allowlist(val origins: List<String>) : CorsConfig()

    fun headerValue(reqOrigin: String?): String? = when (this) {
        is Wildcard -> "*"
        is Exact -> origin
        is Allowlist -> if (reqOrigin != null && origins.contains(reqOrigin)) reqOrigin else null
    }
}

/** Add CORS + PNA headers to a response. */
fun applyCors(call: ApplicationCall, config: CorsConfig) {
    call.response.headers.append("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
    call.response.headers.append("Access-Control-Allow-Headers", "Content-Type, Authorization")
    call.response.headers.append("Access-Control-Allow-Private-Network", "true")
    config.headerValue(call.request.header("Origin"))?.let {
        call.response.headers.append("Access-Control-Allow-Origin", it)
    }
}

/** Install the standard 4-route OpenAI API + OPTIONS preflight + 404 catch-all. */
fun Routing.installDispatchRoutes(handlers: DvaiHandlers, ctx: HandlerContext, config: CorsConfig) {
    options("{...}") {
        applyCors(call, config)
        call.respond(HttpStatusCode.NoContent)
    }
    post("/v1/chat/completions") {
        applyCors(call, config)
        val body = parseBody(call.receiveText())
        respondWithHandlerResponse(call, handlers.handleChatCompletion(body, ctx), config)
    }
    post("/v1/completions") {
        applyCors(call, config)
        val body = parseBody(call.receiveText())
        respondWithHandlerResponse(call, handlers.handleCompletion(body, ctx), config)
    }
    post("/v1/embeddings") {
        applyCors(call, config)
        val body = parseBody(call.receiveText())
        respondWithHandlerResponse(call, handlers.handleEmbeddings(body, ctx), config)
    }
    get("/v1/models") {
        applyCors(call, config)
        respondWithHandlerResponse(call, handlers.handleModels(ctx), config)
    }
    // Catch-all -> 404 with CORS
    route("{...}") {
        handle {
            applyCors(call, config)
            call.respondText(
                buildJsonObject { put("error", "not found") }.toString(),
                ContentType.Application.Json,
                HttpStatusCode.NotFound,
            )
        }
    }
}

private fun parseBody(raw: String): JsonObject {
    if (raw.isBlank()) return JsonObject(emptyMap())
    return try {
        Json.parseToJsonElement(raw) as? JsonObject ?: JsonObject(emptyMap())
    } catch (e: Exception) {
        JsonObject(emptyMap())
    }
}

private suspend fun respondWithHandlerResponse(
    call: ApplicationCall,
    response: HandlerResponse,
    @Suppress("UNUSED_PARAMETER") config: CorsConfig,
) {
    when (response) {
        is HandlerResponse.Json -> {
            call.respondText(
                response.body.toString(),
                ContentType.Application.Json,
                HttpStatusCode.fromValue(response.status),
            )
        }
        is HandlerResponse.Sse -> {
            // SSE: collect into single buffer for Phase 1 (true streaming deferred).
            val buf = StringBuilder()
            response.flow.collect { chunk -> buf.append(chunk) }
            call.respondText(
                buf.toString(),
                ContentType.parse("text/event-stream"),
                HttpStatusCode.OK,
            )
        }
        is HandlerResponse.Error -> {
            call.respondText(
                buildJsonObject { put("error", response.message) }.toString(),
                ContentType.Application.Json,
                HttpStatusCode.fromValue(response.status),
            )
        }
    }
}
