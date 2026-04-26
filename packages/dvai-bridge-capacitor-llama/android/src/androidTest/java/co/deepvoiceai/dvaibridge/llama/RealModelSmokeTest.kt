package co.deepvoiceai.dvaibridge.llama

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * End-to-end smoke test against a small public GGUF model. Verifies
 * mechanics (download → load → respond → free) only, not output quality.
 *
 * Reads `smoke_model_url` / `smoke_model_sha256` from the instrumentation
 * arguments — the workflow forwards them via:
 *
 *     ./gradlew connectedAndroidTest \
 *       -Pandroid.testInstrumentationRunnerArguments.smoke_model_url=$URL \
 *       -Pandroid.testInstrumentationRunnerArguments.smoke_model_sha256=$SHA
 *
 * When either is missing the test is skipped via `Assume.assumeTrue`,
 * so it stays safe to run locally without those args.
 */
@RunWith(AndroidJUnit4::class)
class RealModelSmokeTest {
    private val ctx = InstrumentationRegistry.getInstrumentation().targetContext
    private val args = InstrumentationRegistry.getArguments()
    private var bridge: LlamaCppBridge? = null
    private var tempDir: File? = null

    @After
    fun tearDown() {
        bridge?.unload()
        bridge = null
        tempDir?.deleteRecursively()
        tempDir = null
    }

    /**
     * Vision smoke: download model + mmproj, load both, run a multimodal
     * completion against the tiny test image asset. Skips cleanly if any of
     * smoke_vision_model_url / smoke_vision_model_sha256 /
     * smoke_vision_mmproj_url / smoke_vision_mmproj_sha256 are missing.
     */
    @Test
    fun smokeVisionEndToEnd() {
        val modelUrl = args.getString("smoke_vision_model_url")
        val modelSha = args.getString("smoke_vision_model_sha256")
        val mmprojUrl = args.getString("smoke_vision_mmproj_url")
        val mmprojSha = args.getString("smoke_vision_mmproj_sha256")
        assumeTrue(
            "smoke_vision_* not all provided as instrumentation args; skipping",
            !modelUrl.isNullOrEmpty() && !modelSha.isNullOrEmpty() &&
                !mmprojUrl.isNullOrEmpty() && !mmprojSha.isNullOrEmpty()
        )

        val cacheRoot = File(ctx.cacheDir, "dvai-vision-${System.nanoTime()}")
        cacheRoot.mkdirs()
        tempDir = cacheRoot

        val downloader = ModelDownloader(ctx, cacheDirOverride = cacheRoot)
        val (modelPath, _) = downloader.downloadModel(
            url = modelUrl!!,
            expectedSha256 = modelSha!!.lowercase(),
            destFilename = "smoke-vision-model.gguf",
            headers = emptyMap(),
            onProgress = { _, _ -> },
        )
        val (mmprojPath, _) = downloader.downloadModel(
            url = mmprojUrl!!,
            expectedSha256 = mmprojSha!!.lowercase(),
            destFilename = "smoke-vision-mmproj.gguf",
            headers = emptyMap(),
            onProgress = { _, _ -> },
        )

        val bridge = LlamaCppBridge()
        this.bridge = bridge
        val loaded = bridge.loadModel(
            path = modelPath,
            mmprojPath = null,
            gpuLayers = 99,
            contextSize = 4096,
            threads = 4,
            embeddingMode = false,
        )
        assertTrue("model load should succeed", loaded)
        val mmOk = bridge.loadMmproj(mmprojPath)
        assertTrue("mmproj load should succeed", mmOk)
        assertTrue("bridge should report mmproj loaded", bridge.isMmprojLoaded())

        // Read the tiny PNG from assets (1x1 transparent pixel).
        val imageBytes = ctx.assets.open("images/tiny-test.png").use { it.readBytes() }

        val messages = listOf(mapOf("role" to "user", "content" to "Describe this image: $MTMD_MEDIA_MARKER"))
        val chatPrompt = bridge.applyChatTemplate(
            templateOverride = null,
            messages = messages,
            addAssistant = true,
        )
        assertNotNull("chat template should render", chatPrompt)

        val completion = bridge.completeMultimodalPrompt(
            prompt = chatPrompt!!,
            media = listOf(imageBytes),
            maxTokens = 32,
            temperature = 0.0f,
            topP = 1.0f,
        )
        assertNotNull("vision completion should not be null", completion)
        assertFalse("vision completion should not be empty", completion!!.isEmpty())
    }

    /**
     * Audio smoke: same as vision, but with the WAV fixture. Skipped if the
     * loaded mmproj has no audio encoder.
     */
    @Test
    fun smokeAudioEndToEnd() {
        val modelUrl = args.getString("smoke_vision_model_url")
        val modelSha = args.getString("smoke_vision_model_sha256")
        val mmprojUrl = args.getString("smoke_vision_mmproj_url")
        val mmprojSha = args.getString("smoke_vision_mmproj_sha256")
        assumeTrue(
            "smoke_vision_* not all provided as instrumentation args; skipping",
            !modelUrl.isNullOrEmpty() && !modelSha.isNullOrEmpty() &&
                !mmprojUrl.isNullOrEmpty() && !mmprojSha.isNullOrEmpty()
        )

        val cacheRoot = File(ctx.cacheDir, "dvai-audio-${System.nanoTime()}")
        cacheRoot.mkdirs()
        tempDir = cacheRoot

        val downloader = ModelDownloader(ctx, cacheDirOverride = cacheRoot)
        val (modelPath, _) = downloader.downloadModel(
            url = modelUrl!!,
            expectedSha256 = modelSha!!.lowercase(),
            destFilename = "smoke-audio-model.gguf",
            headers = emptyMap(),
            onProgress = { _, _ -> },
        )
        val (mmprojPath, _) = downloader.downloadModel(
            url = mmprojUrl!!,
            expectedSha256 = mmprojSha!!.lowercase(),
            destFilename = "smoke-audio-mmproj.gguf",
            headers = emptyMap(),
            onProgress = { _, _ -> },
        )

        val bridge = LlamaCppBridge()
        this.bridge = bridge
        bridge.loadModel(
            path = modelPath,
            mmprojPath = null,
            gpuLayers = 99,
            contextSize = 4096,
            threads = 4,
            embeddingMode = false,
        )
        bridge.loadMmproj(mmprojPath)
        assumeTrue("Loaded mmproj reports no audio encoder; skipping audio smoke", bridge.hasAudioEncoder())

        // mtmd accepts wav/mp3/flac for audio. Use the WAV fixture from assets.
        val audioBytes = ctx.assets.open("audio/wav-1s-16khz-mono.wav").use { it.readBytes() }

        val messages = listOf(mapOf("role" to "user", "content" to "Transcribe this: $MTMD_MEDIA_MARKER"))
        val chatPrompt = bridge.applyChatTemplate(
            templateOverride = null,
            messages = messages,
            addAssistant = true,
        )!!

        val completion = bridge.completeMultimodalPrompt(
            prompt = chatPrompt,
            media = listOf(audioBytes),
            maxTokens = 32,
            temperature = 0.0f,
            topP = 1.0f,
        )
        assertNotNull("audio completion should not be null", completion)
        assertFalse("audio completion should not be empty", completion!!.isEmpty())
    }

    @Test
    fun smokeRealModelEndToEnd() {
        val url = args.getString("smoke_model_url")
        val sha = args.getString("smoke_model_sha256")
        assumeTrue(
            "smoke_model_url/smoke_model_sha256 not provided as instrumentation args; skipping",
            !url.isNullOrEmpty() && !sha.isNullOrEmpty()
        )

        val cacheRoot = File(ctx.cacheDir, "dvai-smoke-${System.nanoTime()}")
        cacheRoot.mkdirs()
        tempDir = cacheRoot

        val downloader = ModelDownloader(ctx, cacheDirOverride = cacheRoot)
        val (path, cached) = downloader.downloadModel(
            url = url!!,
            expectedSha256 = sha!!.lowercase(),
            destFilename = "smoke-model.gguf",
            headers = emptyMap(),
            onProgress = { _, _ -> /* no-op for smoke */ },
        )
        assertFalse("first download into a fresh temp dir should not be cached", cached)
        assertTrue("downloaded file should exist at $path", File(path).exists())

        val bridge = LlamaCppBridge()
        this.bridge = bridge
        val loaded = bridge.loadModel(
            path = path,
            mmprojPath = null,
            gpuLayers = 99,
            contextSize = 2048,
            threads = 4,
            embeddingMode = false,
        )
        assertTrue("model load should succeed", loaded)
        assertTrue("bridge should report loaded", bridge.isLoaded())

        val completion = bridge.completePrompt(
            prompt = "<|begin_of_text|>What is 2+2?",
            maxTokens = 32,
            temperature = 0.0f,
            topP = 1.0f,
        )
        // Don't assert specific content — that's quality testing, not smoke.
        assertNotNull("completion should not be null", completion)
        assertFalse("completion should not be empty", completion!!.isEmpty())
    }
}
