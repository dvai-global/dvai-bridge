package co.deepvoiceai.bridge.shared.core

import io.ktor.client.request.*
import io.ktor.client.statement.*
import io.ktor.http.*
import io.ktor.server.routing.*
import io.ktor.server.testing.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class HandlerDispatchTest {
    private val ctx = HandlerContext(modelId = "test-model", backendName = "shared")

    private class FakeHandlers : DvaiHandlers {
        override suspend fun handleChatCompletion(body: JsonObject, ctx: HandlerContext): HandlerResponse =
            HandlerResponse.Json(200, buildJsonObject {
                put("id", "chatcmpl-fake")
                put("object", "chat.completion")
            })

        override suspend fun handleCompletion(body: JsonObject, ctx: HandlerContext): HandlerResponse =
            HandlerResponse.Json(200, buildJsonObject { put("object", "text_completion") })

        override suspend fun handleEmbeddings(body: JsonObject, ctx: HandlerContext): HandlerResponse =
            HandlerResponse.Json(200, buildJsonObject { put("object", "list") })

        override suspend fun handleModels(ctx: HandlerContext): HandlerResponse =
            HandlerResponse.Json(200, buildJsonObject {
                put("object", "list")
                putJsonArray("data") {
                    addJsonObject { put("id", ctx.modelId) }
                }
            })
    }

    @Test
    fun `OPTIONS preflight returns 204 with PNA header`() = testApplication {
        application {
            routing {
                installDispatchRoutes(FakeHandlers(), ctx, CorsConfig.Wildcard)
            }
        }
        val response = client.options("/v1/chat/completions")
        assertEquals(HttpStatusCode.NoContent, response.status)
        assertEquals("true", response.headers["Access-Control-Allow-Private-Network"])
        assertEquals("*", response.headers["Access-Control-Allow-Origin"])
    }

    @Test
    fun `unknown path returns 404`() = testApplication {
        application {
            routing {
                installDispatchRoutes(FakeHandlers(), ctx, CorsConfig.Wildcard)
            }
        }
        val response = client.get("/v1/unknown")
        assertEquals(HttpStatusCode.NotFound, response.status)
    }

    @Test
    fun `GET v1 models returns canned`() = testApplication {
        application {
            routing {
                installDispatchRoutes(FakeHandlers(), ctx, CorsConfig.Wildcard)
            }
        }
        val response = client.get("/v1/models")
        assertEquals(HttpStatusCode.OK, response.status)
        val text = response.bodyAsText()
        val json = Json.parseToJsonElement(text) as JsonObject
        assertEquals("list", json["object"]!!.jsonPrimitive.content)
    }
}
