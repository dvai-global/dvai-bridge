package co.deepvoiceai.bridge.mediapipe.core

import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * JVM unit tests for [MediaPipeHandlers]. Uses a [FakeBridge] implementing
 * [MediaPipeBridgeApi] so tests don't need a real MediaPipe `.task` model.
 *
 * Mirrors the coverage of `LlamaHandlersTest`: chat-completion (sync +
 * streaming), legacy completions, error / 400 surfaces, embeddings rejection,
 * the models endpoint, plus Task 46 vision-capable happy path and image
 * fetch failure surfaces.
 *
 * The `bytesToImage` seam that previously lived in [MediaPipeHandlers] has been
 * moved into [MediaPipeBridge] as part of the Task 17 interface neutralization.
 * [MediaPipeBridgeApi] now accepts [List]<[ByteArray]> rather than
 * [List]<MPImage>. The [FakeBridge] captures raw bytes so tests can assert on
 * the exact payload handed to the bridge, without any Robolectric bitmap
 * overhead.
 */
@RunWith(RobolectricTestRunner::class)
class MediaPipeHandlersTest {
    private val ctx = HandlerContext(modelId = "gemma-2b-it-cpu-int4", backendName = "mediapipe")

    private class FakeBridge(
        var responseToReturn: String = "canned mediapipe response",
        var shouldThrow: Boolean = false,
    ) : MediaPipeBridgeApi {
        var receivedPrompt: String? = null
        var receivedImages: List<ByteArray> = emptyList()
        var asyncCloseCount: Int = 0

        override fun completePrompt(prompt: String, images: List<ByteArray>): String {
            receivedPrompt = prompt
            receivedImages = images
            if (shouldThrow) throw RuntimeException("simulated mediapipe error")
            return responseToReturn
        }

        override fun completePromptAsync(
            prompt: String,
            images: List<ByteArray>,
            onPartial: (String, Boolean) -> Unit,
        ): AutoCloseable {
            receivedPrompt = prompt
            receivedImages = images
            if (shouldThrow) throw RuntimeException("simulated mediapipe error")
            // Synchronously emit two partial chunks then a final done=true. The
            // handler's callbackFlow trySend is non-blocking so this is fine.
            val mid = (responseToReturn.length / 2).coerceAtLeast(0)
            val first = responseToReturn.substring(0, mid)
            val second = responseToReturn.substring(mid)
            onPartial(first, false)
            onPartial(second, true)
            return AutoCloseable { asyncCloseCount += 1 }
        }
    }

    private fun makeHandlers(
        bridge: FakeBridge = FakeBridge(),
        visionCapable: Boolean = false,
    ): MediaPipeHandlers =
        MediaPipeHandlers(
            bridge = bridge,
            modelId = "gemma-2b-it-cpu-int4",
            visionCapable = visionCapable,
        )

    /**
     * Parse a single SSE frame's JSON payload. Returns null for `[DONE]`
     * frames or non-`data:` lines.
     */
    private fun decodeFrame(frame: String): JsonObject? {
        val trimmed = frame.trim()
        if (!trimmed.startsWith("data: ")) return null
        val payload = trimmed.removePrefix("data: ")
        if (payload == "[DONE]") return null
        return Json.parseToJsonElement(payload).jsonObject
    }

    // ----- Chat completion (text happy path) -----

    @Test
    fun `chat completion text happy path`() = runBlocking {
        val bridge = FakeBridge(responseToReturn = "Hello, world!")
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
        assertEquals("gemma-2b-it-cpu-int4", (obj["model"] as JsonPrimitive).content)
        val choices = obj["choices"] as JsonArray
        assertEquals(1, choices.size)
        val msg = (choices[0] as JsonObject)["message"] as JsonObject
        assertEquals("Hello, world!", (msg["content"] as JsonPrimitive).content)
        assertEquals("assistant", (msg["role"] as JsonPrimitive).content)
        assertEquals(
            "stop",
            ((choices[0] as JsonObject)["finish_reason"] as JsonPrimitive).content,
        )
        // Prompt threaded through openAIMessagesToPrompt.
        assertEquals("user: hi", bridge.receivedPrompt)
        // No images provided → empty list passed through.
        assertEquals(0, bridge.receivedImages.size)
        // ID prefix is the MediaPipe-flavored one.
        assertTrue(
            "id should start with chatcmpl-mp-: ${(obj["id"] as JsonPrimitive).content}",
            (obj["id"] as JsonPrimitive).content.startsWith("chatcmpl-mp-"),
        )
    }

    // ----- Streaming -----

    @Test
    fun `chat completion streaming text emits role content content finish-with-content done`() = runBlocking {
        val bridge = FakeBridge(responseToReturn = "abcd")
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

        // Expect: role(0) + 2 content chunks (last one carries finish_reason) + [DONE] = 4 frames
        assertEquals(4, frames.size)

        // Frame 0: role delta
        val frame0 = decodeFrame(frames[0])
            ?: error("frame 0 not decodable")
        val roleDelta = frame0["choices"]?.jsonArray?.first()?.jsonObject
            ?.get("delta")?.jsonObject
        assertEquals("assistant", roleDelta?.get("role")?.jsonPrimitive?.content)
        assertEquals("chat.completion.chunk", frame0["object"]?.jsonPrimitive?.content)

        // Frame 1: first content delta (done=false)
        val frame1 = decodeFrame(frames[1]) ?: error("frame 1 not decodable")
        val choice1 = frame1["choices"]?.jsonArray?.first()?.jsonObject
            ?: error("frame 1 missing choices[0]")
        assertEquals(
            "ab",
            choice1["delta"]?.jsonObject?.get("content")?.jsonPrimitive?.content,
        )
        // finish_reason is JsonNull on the non-final frame
        assertTrue(
            "frame 1 finish_reason should be JsonNull, got ${choice1["finish_reason"]}",
            choice1["finish_reason"] is JsonNull,
        )

        // Frame 2: final content delta (done=true) — carries finish_reason="stop"
        val frame2 = decodeFrame(frames[2]) ?: error("frame 2 not decodable")
        val choice2 = frame2["choices"]?.jsonArray?.first()?.jsonObject
            ?: error("frame 2 missing choices[0]")
        assertEquals(
            "cd",
            choice2["delta"]?.jsonObject?.get("content")?.jsonPrimitive?.content,
        )
        assertEquals(
            "stop",
            choice2["finish_reason"]?.jsonPrimitive?.contentOrNull,
        )

        // Frame 3: [DONE]
        assertEquals("data: [DONE]\n\n", frames[3])
        assertNull(decodeFrame(frames[3]))

        // Bridge.completePromptAsync was called and the AutoCloseable handle was closed.
        assertEquals("user: hi", bridge.receivedPrompt)
        assertEquals(1, bridge.asyncCloseCount)
    }

    // ----- Vision (Task 46) -----

    @Test
    fun `chat completion image part returns 400 when not vision-capable`() = runBlocking {
        // visionCapable = false → image_url request is rejected before image fetch.
        val handlers = makeHandlers(visionCapable = false)
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
        assertTrue(
            "message: ${resp.message}",
            resp.message.contains("vision-capable MediaPipe model"),
        )
        assertTrue(
            "message: ${resp.message}",
            resp.message.contains("visionEnabled"),
        )
    }

    @Test
    fun `chat completion vision-capable image part decodes and threads through bridge`() = runBlocking {
        val bridge = FakeBridge(responseToReturn = "looks like a cat")
        // Use a tiny in-memory PNG via the data URL fixture so the real
        // ImageDecoder.resolve path exercises base64 decoding. Raw bytes are
        // now passed directly to the bridge (ByteArray neutralization, Task 17).
        val handlers = makeHandlers(bridge = bridge, visionCapable = true)
        // Real PNG bytes (1x1 transparent pixel) inlined as base64. Same
        // payload as `tiny-test-base64.txt` but inlined to keep the test
        // self-contained.
        val pngDataUrl =
            "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkAAIAAAoAAv/lxKUAAAAASUVORK5CYII="
        val body = buildJsonObject {
            putJsonArray("messages") {
                addJsonObject {
                    put("role", "user")
                    putJsonArray("content") {
                        addJsonObject {
                            put("type", "text")
                            put("text", "describe this")
                        }
                        addJsonObject {
                            put("type", "image_url")
                            putJsonObject("image_url") {
                                put("url", pngDataUrl)
                            }
                        }
                    }
                }
            }
        }
        val resp = handlers.handleChatCompletion(body, ctx) as? HandlerResponse.Json
            ?: error("expected Json response")
        assertEquals(200, resp.status)
        val obj = resp.body as JsonObject
        val msg = ((obj["choices"] as JsonArray)[0] as JsonObject)["message"] as JsonObject
        assertEquals("looks like a cat", (msg["content"] as JsonPrimitive).content)

        // Bridge received exactly one image (as raw bytes) and the text prompt.
        assertEquals(1, bridge.receivedImages.size)
        // Sanity: first 8 bytes must match the PNG magic header.
        val receivedBytes = bridge.receivedImages[0]
        assertTrue("PNG magic: byte[0]", receivedBytes[0] == 0x89.toByte())
        assertTrue("PNG magic: byte[1]", receivedBytes[1] == 0x50.toByte())
        // Prompt should contain just the text part.
        assertEquals("user: describe this", bridge.receivedPrompt)
    }

    @Test
    fun `chat completion image_url missing url field returns 400`() = runBlocking {
        val handlers = makeHandlers(visionCapable = true)
        val body = buildJsonObject {
            putJsonArray("messages") {
                addJsonObject {
                    put("role", "user")
                    putJsonArray("content") {
                        addJsonObject {
                            put("type", "image_url")
                            putJsonObject("image_url") {
                                // No "url" key.
                            }
                        }
                    }
                }
            }
        }
        val resp = handlers.handleChatCompletion(body, ctx) as? HandlerResponse.Error
            ?: error("expected Error response")
        assertEquals(400, resp.status)
        assertTrue(
            "message: ${resp.message}",
            resp.message.contains("missing 'url' field"),
        )
    }

    @Test
    fun `chat completion image fetch failure returns 502`() = runBlocking {
        val handlers = makeHandlers(visionCapable = true)
        val body = buildJsonObject {
            putJsonArray("messages") {
                addJsonObject {
                    put("role", "user")
                    putJsonArray("content") {
                        addJsonObject {
                            put("type", "image_url")
                            putJsonObject("image_url") {
                                // Unsupported scheme — ImageDecoder.resolve throws InvalidScheme.
                                put("url", "ftp://example.com/x.png")
                            }
                        }
                    }
                }
            }
        }
        val resp = handlers.handleChatCompletion(body, ctx) as? HandlerResponse.Error
            ?: error("expected Error response")
        assertEquals(502, resp.status)
        assertTrue(
            "message: ${resp.message}",
            resp.message.contains("Failed to fetch image"),
        )
    }

    @Test
    fun `chat completion streaming vision-capable image part threads raw bytes through bridge`() = runBlocking {
        // Verify that the streaming path passes raw ByteArray to the bridge
        // rather than converting to MPImage in the handler layer (Task 17
        // neutralization: ByteArray → MPImage conversion now happens inside
        // MediaPipeBridge, not in MediaPipeHandlers).
        val bridge = FakeBridge(responseToReturn = "ab")
        val handlers = makeHandlers(bridge = bridge, visionCapable = true)
        val pngDataUrl =
            "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkAAIAAAoAAv/lxKUAAAAASUVORK5CYII="
        val body = buildJsonObject {
            putJsonArray("messages") {
                addJsonObject {
                    put("role", "user")
                    putJsonArray("content") {
                        addJsonObject { put("type", "text"); put("text", "what is this") }
                        addJsonObject {
                            put("type", "image_url")
                            putJsonObject("image_url") { put("url", pngDataUrl) }
                        }
                    }
                }
            }
            put("stream", true)
        }
        val resp = handlers.handleChatCompletion(body, ctx) as? HandlerResponse.Sse
            ?: error("expected Sse response")
        resp.flow.toList() // consume the stream to completion
        // Bridge received one raw-byte image via the streaming path.
        assertEquals(1, bridge.receivedImages.size)
        val receivedBytes = bridge.receivedImages[0]
        assertTrue("PNG magic byte[0]", receivedBytes[0] == 0x89.toByte())
        assertTrue("PNG magic byte[1]", receivedBytes[1] == 0x50.toByte())
    }

    // ----- 400 surfaces -----

    @Test
    fun `chat completion audio part returns 400`() = runBlocking {
        val handlers = makeHandlers()
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
        assertTrue("message: ${resp.message}", resp.message.contains("Audio input not supported"))
    }

    @Test
    fun `chat completion missing messages returns 400`() = runBlocking {
        val handlers = makeHandlers()
        val resp = handlers.handleChatCompletion(buildJsonObject {}, ctx) as? HandlerResponse.Error
            ?: error("expected Error response")
        assertEquals(400, resp.status)
        assertTrue("message: ${resp.message}", resp.message.contains("messages"))
    }

    @Test
    fun `chat completion empty messages returns 400`() = runBlocking {
        val handlers = makeHandlers()
        val body = buildJsonObject {
            putJsonArray("messages") { /* empty */ }
        }
        val resp = handlers.handleChatCompletion(body, ctx) as? HandlerResponse.Error
            ?: error("expected Error response")
        assertEquals(400, resp.status)
        assertTrue("message: ${resp.message}", resp.message.contains("Empty"))
    }

    @Test
    fun `chat completion bridge throw returns 500`() = runBlocking {
        val bridge = FakeBridge(shouldThrow = true)
        val handlers = makeHandlers(bridge = bridge)
        val body = buildJsonObject {
            putJsonArray("messages") {
                addJsonObject {
                    put("role", "user")
                    put("content", "hi")
                }
            }
        }
        val resp = handlers.handleChatCompletion(body, ctx) as? HandlerResponse.Error
            ?: error("expected Error response")
        assertEquals(500, resp.status)
        assertTrue("message: ${resp.message}", resp.message.contains("simulated mediapipe error"))
    }

    // ----- Legacy completions -----

    @Test
    fun `legacy completion converts to text_completion shape`() = runBlocking {
        val bridge = FakeBridge(responseToReturn = "canned-text")
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
        assertNotNull(choice0["logprobs"])
        // ID rewritten chatcmpl-mp- → cmpl-mp-
        val idStr = (obj["id"] as JsonPrimitive).content
        assertTrue("id should start with cmpl-: $idStr", idStr.startsWith("cmpl-"))
        // Prompt was wrapped as a user message and threaded through.
        assertEquals("user: say hi", bridge.receivedPrompt)
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
        // The prompt array is joined with \n, then wrapped as a single user message.
        assertEquals("user: alpha\nbeta", bridge.receivedPrompt)
    }

    // ----- Embeddings -----

    @Test
    fun `embeddings always returns 400 with redirect message`() = runBlocking {
        val handlers = makeHandlers()
        val resp = handlers.handleEmbeddings(
            buildJsonObject { put("input", "hello") },
            ctx,
        ) as? HandlerResponse.Error ?: error("expected Error response")
        assertEquals(400, resp.status)
        assertTrue(
            "message: ${resp.message}",
            resp.message.contains("Embeddings not supported on MediaPipe LLM"),
        )
        assertTrue(
            "message: ${resp.message}",
            resp.message.contains("capacitorBackend: \"llama\""),
        )
    }

    // ----- Models -----

    @Test
    fun `models returns single google-mediapipe entry with ctx modelId`() = runBlocking {
        val handlers = makeHandlers()
        val customCtx = HandlerContext(modelId = "/path/to/gemma-2b.task", backendName = "mediapipe")
        val resp = handlers.handleModels(customCtx) as? HandlerResponse.Json
            ?: error("expected Json response")
        assertEquals(200, resp.status)
        val obj = resp.body as JsonObject
        assertEquals("list", (obj["object"] as JsonPrimitive).content)
        val data = obj["data"] as JsonArray
        assertEquals(1, data.size)
        val entry0 = data[0] as JsonObject
        assertEquals("/path/to/gemma-2b.task", (entry0["id"] as JsonPrimitive).content)
        assertEquals("model", (entry0["object"] as JsonPrimitive).content)
        assertEquals("google-mediapipe", (entry0["owned_by"] as JsonPrimitive).content)
    }
}
