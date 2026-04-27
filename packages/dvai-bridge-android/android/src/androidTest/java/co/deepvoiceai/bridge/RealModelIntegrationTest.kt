package co.deepvoiceai.bridge

import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.ext.junit.runners.AndroidJUnit4
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assume.assumeFalse
import org.junit.Test
import org.junit.runner.RunWith
import kotlinx.coroutines.runBlocking
import java.io.File
import java.security.MessageDigest

/**
 * End-to-end integration tests for the Android Native SDK against real models.
 * Each backend has its own test method; each skips cleanly when its
 * prereqs aren't met (env vars / BuildConfig fields missing).
 *
 * Mirrors the iOS `RealModelIntegrationTest.swift` pattern.
 *
 * Set env vars on the host (read by Gradle into BuildConfig via Task 17's
 * `buildConfigField` injection):
 *   - SMOKE_MODEL_URL + SMOKE_MODEL_SHA256        (Llama)
 *   - SMOKE_MEDIAPIPE_MODEL_URL + SMOKE_MEDIAPIPE_MODEL_SHA256
 *   - SMOKE_LITERT_MODEL_URL + SMOKE_LITERT_MODEL_SHA256 + SMOKE_LITERT_TOKENIZER_URL
 *
 * Run: `./gradlew :dvai-bridge-android:connectedAndroidTest` against a
 * connected device or emulator.
 */
@RunWith(AndroidJUnit4::class)
class RealModelIntegrationTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val httpClient = OkHttpClient()

    @After
    fun tearDown() = runBlocking {
        runCatching { DVAIBridge.stop() }
    }

    @Test
    fun llamaBackendIntegration() = runBlocking {
        val url = BuildConfig.SMOKE_MODEL_URL
        val sha = BuildConfig.SMOKE_MODEL_SHA256
        assumeFalse("SMOKE_MODEL_URL not set", url.isEmpty())
        assumeFalse("SMOKE_MODEL_SHA256 not set", sha.isEmpty())

        DVAIBridge.init(context)
        val download = DVAIBridge.downloadModel(
            DownloadOptions(url = url, sha256 = sha, destFilename = "int-llama.gguf"),
        )

        val server = DVAIBridge.start(StartOptions(
            backend = BackendKind.Llama,
            modelPath = download.path,
            // GPU offload off by default on emulator (no Vulkan).
            gpuLayers = 0,
            contextSize = 1024,
        ))
        assertEquals(BackendKind.Llama, server.backend)

        val response = postChatCompletion(server.baseUrl, "What is 2+2?")
        assertFalse("llama completion should not be empty", response.isEmpty())
    }

    @Test
    fun mediaPipeBackendIntegration() = runBlocking {
        val url = BuildConfig.SMOKE_MEDIAPIPE_MODEL_URL
        val sha = BuildConfig.SMOKE_MEDIAPIPE_MODEL_SHA256
        assumeFalse("SMOKE_MEDIAPIPE_MODEL_URL not set", url.isEmpty())
        assumeFalse("SMOKE_MEDIAPIPE_MODEL_SHA256 not set", sha.isEmpty())

        DVAIBridge.init(context)
        val download = DVAIBridge.downloadModel(
            DownloadOptions(url = url, sha256 = sha, destFilename = "int-mediapipe.task"),
        )

        val server = DVAIBridge.start(StartOptions(
            backend = BackendKind.MediaPipe,
            modelPath = download.path,
        ))
        assertEquals(BackendKind.MediaPipe, server.backend)

        val response = postChatCompletion(server.baseUrl, "Hello")
        assertFalse("mediapipe completion should not be empty", response.isEmpty())
    }

    @Test
    fun liteRTBackendIntegration() = runBlocking {
        val modelUrl = BuildConfig.SMOKE_LITERT_MODEL_URL
        val modelSha = BuildConfig.SMOKE_LITERT_MODEL_SHA256
        val tokUrl = BuildConfig.SMOKE_LITERT_TOKENIZER_URL
        assumeFalse("SMOKE_LITERT_MODEL_URL not set", modelUrl.isEmpty())
        assumeFalse("SMOKE_LITERT_MODEL_SHA256 not set", modelSha.isEmpty())
        assumeFalse("SMOKE_LITERT_TOKENIZER_URL not set", tokUrl.isEmpty())

        DVAIBridge.init(context)
        val modelDownload = DVAIBridge.downloadModel(
            DownloadOptions(url = modelUrl, sha256 = modelSha, destFilename = "int-litert.tflite"),
        )
        // tokenizer.json: download into the same cache dir, no sha required (small file).
        val tokDir = File(modelDownload.path).parentFile ?: error("download path has no parent")
        val tokFile = File(tokDir, "tokenizer.json")
        downloadRaw(tokUrl, tokFile)

        val server = DVAIBridge.start(StartOptions(
            backend = BackendKind.LiteRT,
            modelPath = modelDownload.path,
            tokenizerPath = tokDir.absolutePath,
            maxNewTokens = 32,
        ))
        assertEquals(BackendKind.LiteRT, server.backend)

        val response = postChatCompletion(server.baseUrl, "What is 2+2?")
        assertFalse("litert completion should not be empty", response.isEmpty())
    }

    private fun postChatCompletion(baseUrl: String, userMessage: String): String {
        val body = JSONObject().apply {
            put("messages", JSONArray().apply {
                put(JSONObject().apply {
                    put("role", "user")
                    put("content", userMessage)
                })
            })
            put("max_tokens", 32)
            put("temperature", 0.0)
        }.toString()
        val req = Request.Builder()
            .url("$baseUrl/chat/completions")
            .post(body.toRequestBody("application/json".toMediaType()))
            .build()
        httpClient.newCall(req).execute().use { resp ->
            val text = resp.body?.string() ?: ""
            assertNotNull("response body", text)
            if (resp.code != 200) error("POST failed: ${resp.code} $text")
            val json = JSONObject(text)
            val choices = json.optJSONArray("choices") ?: return ""
            if (choices.length() == 0) return ""
            val message = choices.getJSONObject(0).optJSONObject("message") ?: return ""
            return message.optString("content", "")
        }
    }

    private fun downloadRaw(url: String, dest: File) {
        val req = Request.Builder().url(url).build()
        httpClient.newCall(req).execute().use { resp ->
            if (resp.code != 200) error("downloadRaw($url) -> ${resp.code}")
            dest.outputStream().use { out -> resp.body!!.byteStream().copyTo(out) }
        }
    }

    private fun assertEquals(expected: BackendKind, actual: BackendKind) {
        if (expected != actual) error("expected $expected, got $actual")
    }
}
