package co.deepvoiceai.dvaibridge.llama

import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * JVM unit tests for [LlamaHandlers]. Uses a [FakeBridge] implementing
 * [LlamaCppBridgeApi] so tests don't need a real GGUF model loaded.
 */
class LlamaHandlersTest {
    private val ctx = HandlerContext(modelId = "test-model", backendName = "llama")

    private class FakeBridge(
        var loaded: Boolean = true,
        var completionToReturn: String? = "canned response",
        var embeddingToReturn: FloatArray? = floatArrayOf(0.1f, 0.2f, 0.3f),
    ) : LlamaCppBridgeApi {
        var receivedPrompt: String? = null
        val receivedEmbeddingTexts = mutableListOf<String>()

        override fun isLoaded(): Boolean = loaded
        override fun completePrompt(prompt: String, maxTokens: Int, temperature: Float, topP: Float): String? {
            receivedPrompt = prompt
            return completionToReturn
        }
        override fun embedding(text: String): FloatArray? {
            receivedEmbeddingTexts += text
            return embeddingToReturn
        }
    }

    private fun makeHandlers(
        bridge: FakeBridge = FakeBridge(),
        mmprojLoaded: Boolean = false,
        modelHasAudioEncoder: Boolean = false,
        embeddingMode: Boolean = false,
    ): LlamaHandlers = LlamaHandlers(
        bridge = bridge,
        modelId = "test-model",
        mmprojLoaded = mmprojLoaded,
        modelHasAudioEncoder = modelHasAudioEncoder,
        embeddingMode = embeddingMode,
    )

    // ----- Chat completion -----

    @Test
    fun `chat completion text happy path`() = runBlocking {
        val bridge = FakeBridge(completionToReturn = "Hello, world!")
        val handlers = makeHandlers(bridge = bridge)
        val body = buildJsonObject {
            putJsonArray("messages") {
                addJsonObject {
                    put("role", "user")
                    put("content", "hi")
                }
            }
        }
        val resp = handlers.handleChatCompletion(body, ctx) as? HandlerResponse.Json
            ?: error("expected Json response")
        assertEquals(200, resp.status)
        val obj = resp.body as JsonObject
        assertEquals("chat.completion", (obj["object"] as JsonPrimitive).content)
        assertEquals("test-model", (obj["model"] as JsonPrimitive).content)
        val choices = obj["choices"] as JsonArray
        assertEquals(1, choices.size)
        val msg = (choices[0] as JsonObject)["message"] as JsonObject
        assertEquals("Hello, world!", (msg["content"] as JsonPrimitive).content)
        assertEquals("assistant", (msg["role"] as JsonPrimitive).content)
        assertEquals("stop", ((choices[0] as JsonObject)["finish_reason"] as JsonPrimitive).content)
        assertEquals("hi", bridge.receivedPrompt)
    }

    @Test
    fun `chat completion streaming text emits role content finish done`() = runBlocking {
        val bridge = FakeBridge(completionToReturn = "stream-canned")
        val handlers = makeHandlers(bridge = bridge)
        val body = buildJsonObject {
            putJsonArray("messages") {
                addJsonObject {
                    put("role", "user")
                    put("content", "hi")
                }
            }
            put("stream", true)
        }
        val resp = handlers.handleChatCompletion(body, ctx) as? HandlerResponse.Sse
            ?: error("expected Sse response")
        val frames = resp.flow.toList()
        assertEquals(4, frames.size)
        assertTrue("frame 0 should be role delta: ${frames[0]}", frames[0].contains("\"role\":\"assistant\""))
        assertTrue("frame 1 should contain content: ${frames[1]}", frames[1].contains("stream-canned"))
        assertTrue("frame 2 should have finish_reason: ${frames[2]}", frames[2].contains("\"finish_reason\":\"stop\""))
        assertEquals("data: [DONE]\n\n", frames[3])
    }

    @Test
    fun `chat completion image without mmproj returns 400`() = runBlocking {
        val handlers = makeHandlers(mmprojLoaded = false)
        val body = buildJsonObject {
            putJsonArray("messages") {
                addJsonObject {
                    put("role", "user")
                    putJsonArray("content") {
                        addJsonObject {
                            put("type", "image_url")
                            putJsonObject("image_url") {
                                put("url", "data:image/png;base64,iVBOR")
                            }
                        }
                    }
                }
            }
        }
        val resp = handlers.handleChatCompletion(body, ctx) as? HandlerResponse.Error
            ?: error("expected Error response")
        assertEquals(400, resp.status)
        assertTrue("message: ${resp.message}", resp.message.contains("no mmproj was loaded"))
        assertTrue("message: ${resp.message}", resp.message.contains("nativeMmprojPath"))
    }

    @Test
    fun `chat completion audio without encoder returns 400`() = runBlocking {
        val handlers = makeHandlers(modelHasAudioEncoder = false)
        val body = buildJsonObject {
            putJsonArray("messages") {
                addJsonObject {
                    put("role", "user")
                    putJsonArray("content") {
                        addJsonObject {
                            put("type", "input_audio")
                            putJsonObject("input_audio") {
                                put("data", "AAAA")
                                put("format", "pcm16")
                            }
                        }
                    }
                }
            }
        }
        val resp = handlers.handleChatCompletion(body, ctx) as? HandlerResponse.Error
            ?: error("expected Error response")
        assertEquals(400, resp.status)
        assertTrue("message: ${resp.message}", resp.message.contains("native audio encoder"))
    }

    @Test
    fun `chat completion missing messages returns 400`() = runBlocking {
        val handlers = makeHandlers()
        val resp = handlers.handleChatCompletion(buildJsonObject {}, ctx) as? HandlerResponse.Error
            ?: error("expected Error response")
        assertEquals(400, resp.status)
        assertTrue("message: ${resp.message}", resp.message.contains("messages"))
    }

    // ----- Legacy completions -----

    @Test
    fun `legacy completion converts to text_completion shape`() = runBlocking {
        val bridge = FakeBridge(completionToReturn = "canned-text")
        val handlers = makeHandlers(bridge = bridge)
        val body = buildJsonObject { put("prompt", "say hi") }
        val resp = handlers.handleCompletion(body, ctx) as? HandlerResponse.Json
            ?: error("expected Json response")
        assertEquals(200, resp.status)
        val obj = resp.body as JsonObject
        assertEquals("text_completion", (obj["object"] as JsonPrimitive).content)
        val choices = obj["choices"] as JsonArray
        val choice0 = choices[0] as JsonObject
        assertEquals("canned-text", (choice0["text"] as JsonPrimitive).content)
        assertEquals("stop", (choice0["finish_reason"] as JsonPrimitive).content)
        // logprobs key present (JsonNull)
        assertNotNull(choice0["logprobs"])
        // ID rewritten chatcmpl- → cmpl-
        val idStr = (obj["id"] as JsonPrimitive).content
        assertTrue("id should start with cmpl-: $idStr", idStr.startsWith("cmpl-"))
        assertEquals("say hi", bridge.receivedPrompt)
    }

    @Test
    fun `legacy completion array prompt joined with newline`() = runBlocking {
        val bridge = FakeBridge()
        val handlers = makeHandlers(bridge = bridge)
        val body = buildJsonObject {
            putJsonArray("prompt") {
                add("alpha")
                add("beta")
            }
        }
        val resp = handlers.handleCompletion(body, ctx) as? HandlerResponse.Json
            ?: error("expected Json response")
        assertEquals(200, resp.status)
        assertEquals("alpha\nbeta", bridge.receivedPrompt)
    }

    // ----- Embeddings -----

    @Test
    fun `embeddings rejected when not embedding mode`() = runBlocking {
        val handlers = makeHandlers(embeddingMode = false)
        val resp = handlers.handleEmbeddings(
            buildJsonObject { put("input", "hello") },
            ctx,
        ) as? HandlerResponse.Error ?: error("expected Error response")
        assertEquals(400, resp.status)
        assertTrue("message: ${resp.message}", resp.message.contains("nativeEmbeddingMode"))
    }

    @Test
    fun `embeddings happy path single string`() = runBlocking {
        val bridge = FakeBridge(embeddingToReturn = floatArrayOf(0.5f, -0.25f, 1.0f))
        val handlers = makeHandlers(bridge = bridge, embeddingMode = true)
        val resp = handlers.handleEmbeddings(
            buildJsonObject { put("input", "hello") },
            ctx,
        ) as? HandlerResponse.Json ?: error("expected Json response")
        assertEquals(200, resp.status)
        val obj = resp.body as JsonObject
        assertEquals("list", (obj["object"] as JsonPrimitive).content)
        assertEquals("test-model", (obj["model"] as JsonPrimitive).content)
        val data = obj["data"] as JsonArray
        assertEquals(1, data.size)
        val entry0 = data[0] as JsonObject
        assertEquals("embedding", (entry0["object"] as JsonPrimitive).content)
        assertEquals(0, (entry0["index"] as JsonPrimitive).intOrNull)
        val vec = entry0["embedding"] as JsonArray
        assertEquals(3, vec.size)
        assertEquals(0.5, (vec[0] as JsonPrimitive).content.toDouble(), 1e-6)
        assertEquals(-0.25, (vec[1] as JsonPrimitive).content.toDouble(), 1e-6)
        assertEquals(1.0, (vec[2] as JsonPrimitive).content.toDouble(), 1e-6)
        assertEquals(listOf("hello"), bridge.receivedEmbeddingTexts)
    }

    @Test
    fun `embeddings array input produces multiple entries`() = runBlocking {
        val bridge = FakeBridge()
        val handlers = makeHandlers(bridge = bridge, embeddingMode = true)
        val resp = handlers.handleEmbeddings(
            buildJsonObject {
                putJsonArray("input") {
                    add("alpha")
                    add("beta")
                    add("gamma")
                }
            },
            ctx,
        ) as? HandlerResponse.Json ?: error("expected Json response")
        assertEquals(200, resp.status)
        val data = (resp.body as JsonObject)["data"] as JsonArray
        assertEquals(3, data.size)
        assertEquals(0, ((data[0] as JsonObject)["index"] as JsonPrimitive).intOrNull)
        assertEquals(1, ((data[1] as JsonObject)["index"] as JsonPrimitive).intOrNull)
        assertEquals(2, ((data[2] as JsonObject)["index"] as JsonPrimitive).intOrNull)
        assertEquals(listOf("alpha", "beta", "gamma"), bridge.receivedEmbeddingTexts)
    }

    @Test
    fun `embeddings missing input returns 400`() = runBlocking {
        val handlers = makeHandlers(embeddingMode = true)
        val resp = handlers.handleEmbeddings(buildJsonObject {}, ctx) as? HandlerResponse.Error
            ?: error("expected Error response")
        assertEquals(400, resp.status)
    }

    // ----- Models -----

    @Test
    fun `models returns single entry list with ctx modelId`() = runBlocking {
        val handlers = makeHandlers()
        val customCtx = HandlerContext(modelId = "/path/to/model.gguf", backendName = "llama")
        val resp = handlers.handleModels(customCtx) as? HandlerResponse.Json
            ?: error("expected Json response")
        assertEquals(200, resp.status)
        val obj = resp.body as JsonObject
        assertEquals("list", (obj["object"] as JsonPrimitive).content)
        val data = obj["data"] as JsonArray
        assertEquals(1, data.size)
        assertEquals("/path/to/model.gguf", ((data[0] as JsonObject)["id"] as JsonPrimitive).content)
    }
}
