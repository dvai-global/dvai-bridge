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
