package co.deepvoiceai.dvaibridge.llama

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.longOrNull
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.util.Base64

class ContentPartsTranslatorTest {
    // region Mocks

    /** Image decoder that returns canned bytes per URL and records calls. */
    private class MockImageDecoder {
        val responses = mutableMapOf<String, ByteArray>()
        val calls = mutableListOf<String>()
        fun resolve(url: String): ByteArray {
            calls += url
            return responses[url] ?: byteArrayOf(0xDE.toByte(), 0xAD.toByte(), 0xBE.toByte(), 0xEF.toByte())
        }
    }

    /** Records every audio decode call's `(bytesIn, format)`. */
    private class AudioRecorder {
        val calls = mutableListOf<Pair<ByteArray, AudioFormat>>()
        var pcmOut: ByteArray = byteArrayOf(0x11, 0x22, 0x33, 0x44)
        fun decode(data: ByteArray, format: AudioFormat): ByteArray {
            calls += data to format
            return pcmOut
        }
    }

    // endregion

    // region Fixture loader

    /** Walks up from the gradle module dir until it finds the repo-root `fixtures/` dir. */
    private fun fixturesDir(): File {
        var dir = File(".").canonicalFile
        while (!File(dir, "fixtures").isDirectory) {
            dir = dir.parentFile ?: error("fixtures dir not found walking up from ${File(".").canonicalPath}")
        }
        return File(dir, "fixtures")
    }

    /**
     * Load a fixture out of `transport-fixtures.json` and return its `messages`
     * array as `List<Map<String, Any?>>` — the shape the translator consumes.
     * For `CHAT_REQUEST_AUDIO_PCM16` the placeholder `data` field is replaced
     * with the base64 of the `pcm16-1s-16khz-mono.bin` fixture before return.
     */
    private fun loadMessages(key: String): List<Map<String, Any?>> {
        val text = File(fixturesDir(), "transport-fixtures.json").readText(Charsets.UTF_8)
        val root = Json.parseToJsonElement(text).jsonObject
        val fixture = root[key]?.jsonObject ?: error("missing fixture: $key")
        val messagesArray = fixture["messages"] as? JsonArray
            ?: error("fixture $key has no messages array")
        @Suppress("UNCHECKED_CAST")
        val messages = messagesArray.map { (it.toAny() as Map<String, Any?>).toMutableMap() }
            .toMutableList()
        if (key == "CHAT_REQUEST_AUDIO_PCM16") {
            // Replace the placeholder `data` field on the audio part with
            // base64(PCM16 fixture file) so the translator's base64-decode
            // round-trips back to the raw PCM bytes.
            val pcmBytes = File(fixturesDir(), "audio/pcm16-1s-16khz-mono.bin").readBytes()
            val b64 = Base64.getEncoder().encodeToString(pcmBytes)
            val msg0 = (messages[0]).toMutableMap()
            @Suppress("UNCHECKED_CAST")
            val parts = (msg0["content"] as List<Map<String, Any?>>).map { it.toMutableMap() }.toMutableList()
            val part0 = parts[0]
            @Suppress("UNCHECKED_CAST")
            val audioObj = (part0["input_audio"] as Map<String, Any?>).toMutableMap()
            audioObj["data"] = b64
            part0["input_audio"] = audioObj
            parts[0] = part0
            msg0["content"] = parts
            messages[0] = msg0
        }
        return messages
    }

    /**
     * Convert a `JsonElement` tree to a vanilla Kotlin `Any?` tree
     * (`Map<String, Any?>`, `List<Any?>`, `String`, `Number`, `Boolean`, `null`)
     * — the shape the translator's `translate()` consumes.
     */
    private fun JsonElement.toAny(): Any? = when (this) {
        is JsonObject -> this.mapValues { it.value.toAny() }
        is JsonArray -> this.map { it.toAny() }
        is JsonPrimitive -> {
            if (this.isString) this.contentOrNull
            else this.booleanOrNull ?: this.longOrNull ?: this.doubleOrNull ?: this.contentOrNull
        }
    }

    // endregion

    // region Happy paths

    /** `CHAT_REQUEST_TEXT` — legacy string content → prompt only. */
    @Test
    fun `text-only message produces prompt and no media`() = runBlocking {
        val translator = ContentPartsTranslator(mmprojLoaded = false, modelHasAudioEncoder = false)
        val result = translator.translate(loadMessages("CHAT_REQUEST_TEXT"))
        assertEquals("hi", result.prompt)
        assertTrue(result.images.isEmpty())
        assertTrue(result.audioPCM.isEmpty())
    }

    /** `CHAT_REQUEST_IMAGE` — text + data-URL image. */
    @Test
    fun `text plus image part populates images via decoder`() = runBlocking {
        val messages = loadMessages("CHAT_REQUEST_IMAGE")
        // Pull the image URL from the fixture so the mock can match exactly.
        @Suppress("UNCHECKED_CAST")
        val parts = (messages[0]["content"] as List<Map<String, Any?>>)
        @Suppress("UNCHECKED_CAST")
        val urlFromFixture = (parts.first { it["type"] == "image_url" }["image_url"] as Map<String, Any?>)["url"] as String

        val mock = MockImageDecoder().apply {
            responses[urlFromFixture] = byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x99.toByte())
        }
        val translator = ContentPartsTranslator(
            mmprojLoaded = true,
            modelHasAudioEncoder = false,
            imageDecoder = { url -> mock.resolve(url) },
        )
        val result = translator.translate(messages)
        assertEquals("What is in this image?", result.prompt)
        assertEquals(1, result.images.size)
        assertArrayEquals(mock.responses[urlFromFixture], result.images[0])
        assertEquals(listOf(urlFromFixture), mock.calls)
        assertTrue(result.audioPCM.isEmpty())
    }

    /** `CHAT_REQUEST_AUDIO_PCM16` — base64 PCM + text. */
    @Test
    fun `audio pcm16 part is base64-decoded and forwarded to audio decoder`() = runBlocking {
        val messages = loadMessages("CHAT_REQUEST_AUDIO_PCM16")
        val recorder = AudioRecorder()
        val translator = ContentPartsTranslator(
            mmprojLoaded = false,
            modelHasAudioEncoder = true,
            audioDecoder = { data, fmt -> recorder.decode(data, fmt) },
        )
        val result = translator.translate(messages)
        assertEquals("Transcribe this.", result.prompt)
        assertTrue(result.images.isEmpty())
        assertEquals(1, result.audioPCM.size)
        assertArrayEquals(recorder.pcmOut, result.audioPCM[0])
        assertEquals(1, recorder.calls.size)
        assertEquals(AudioFormat.PCM16, recorder.calls[0].second)
        // Recorder receives the raw decoded PCM bytes (base64-decoded by the
        // translator), which round-trip back to the source PCM file.
        val pcmFile = File(fixturesDir(), "audio/pcm16-1s-16khz-mono.bin").readBytes()
        assertArrayEquals(pcmFile, recorder.calls[0].first)
    }

    // endregion

    // region Negative paths

    /** Image part with `mmprojLoaded == false` → `NoMmprojForImage`. */
    @Test
    fun `image without mmproj throws and skips decoder`() = runBlocking {
        val mock = MockImageDecoder()
        val translator = ContentPartsTranslator(
            mmprojLoaded = false,
            modelHasAudioEncoder = false,
            imageDecoder = { url -> mock.resolve(url) },
        )
        val messages = listOf(
            mapOf<String, Any?>(
                "role" to "user",
                "content" to listOf(
                    mapOf("type" to "image_url", "image_url" to mapOf("url" to "data:image/png;base64,AAAA")),
                ),
            ),
        )
        try {
            translator.translate(messages)
            fail("expected NoMmprojForImage")
        } catch (e: TranslatorError.NoMmprojForImage) {
            assertTrue("decoder should not be called when mmproj is missing", mock.calls.isEmpty())
        }
        Unit
    }

    /** Audio part with `modelHasAudioEncoder == false` → `AudioWithoutAudioEncoder`. */
    @Test
    fun `audio without encoder throws`() = runBlocking {
        val translator = ContentPartsTranslator(mmprojLoaded = false, modelHasAudioEncoder = false)
        val messages = listOf(
            mapOf<String, Any?>(
                "role" to "user",
                "content" to listOf(
                    mapOf("type" to "input_audio", "input_audio" to mapOf("data" to "AAAA", "format" to "pcm16")),
                ),
            ),
        )
        try {
            translator.translate(messages)
            fail("expected AudioWithoutAudioEncoder")
        } catch (_: TranslatorError.AudioWithoutAudioEncoder) {
            // expected
        }
        Unit
    }

    /** Unsupported audio format (e.g. `vorbis`) → `UnsupportedAudioFormat`. */
    @Test
    fun `unsupported audio format throws with platform list`() = runBlocking {
        val translator = ContentPartsTranslator(mmprojLoaded = false, modelHasAudioEncoder = true)
        val messages = listOf(
            mapOf<String, Any?>(
                "role" to "user",
                "content" to listOf(
                    mapOf("type" to "input_audio", "input_audio" to mapOf("data" to "AAAA", "format" to "vorbis")),
                ),
            ),
        )
        try {
            translator.translate(messages)
            fail("expected UnsupportedAudioFormat")
        } catch (e: TranslatorError.UnsupportedAudioFormat) {
            assertEquals("vorbis", e.format)
            assertEquals(ContentPartsTranslator.SUPPORTED_AUDIO_FORMATS, e.supported)
            assertTrue("Android supported list should include ogg", e.supported.contains("ogg"))
        }
        Unit
    }

    /** Unknown content part type → `MalformedRequest` mentioning the type. */
    @Test
    fun `unknown content part type throws MalformedRequest`() = runBlocking {
        val translator = ContentPartsTranslator(mmprojLoaded = true, modelHasAudioEncoder = true)
        val messages = listOf(
            mapOf<String, Any?>(
                "role" to "user",
                "content" to listOf(
                    mapOf("type" to "video_url", "video_url" to mapOf("url" to "https://example.com/v.mp4")),
                ),
            ),
        )
        try {
            translator.translate(messages)
            fail("expected MalformedRequest")
        } catch (e: TranslatorError.MalformedRequest) {
            assertTrue("expected message to mention 'video_url', got: ${e.message}", (e.message ?: "").contains("video_url"))
        }
        Unit
    }

    // endregion
}
