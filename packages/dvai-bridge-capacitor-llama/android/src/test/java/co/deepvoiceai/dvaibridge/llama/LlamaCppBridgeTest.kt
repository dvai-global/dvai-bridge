package co.deepvoiceai.dvaibridge.llama

import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * JVM unit tests for LlamaCppBridge's pure-Kotlin state machine.
 * JNI methods aren't loadable here (no .so on JVM classpath); that's
 * exercised by instrumented tests on a device/emulator (later tier).
 *
 * Robolectric is used so System.loadLibrary's UnsatisfiedLinkError
 * is caught gracefully (the bridge falls through to a stub state).
 */
@RunWith(RobolectricTestRunner::class)
class LlamaCppBridgeTest {

    @Test
    fun `initially not loaded`() {
        val bridge = LlamaCppBridge()
        assertFalse(bridge.isLoaded())
        assertNull(bridge.getCurrentModelPath())
    }

    @Test
    fun `loadModel with empty path returns false`() {
        val bridge = LlamaCppBridge()
        val ok = bridge.loadModel(
            path = "",
            mmprojPath = null,
            gpuLayers = 99,
            contextSize = 2048,
            threads = 4,
            embeddingMode = false,
        )
        assertFalse(ok)
        assertFalse(bridge.isLoaded())
    }

    @Test
    fun `loadModel + unload cycle updates state`() {
        val bridge = LlamaCppBridge()
        val ok = bridge.loadModel(
            path = "/tmp/fake.gguf",
            mmprojPath = null,
            gpuLayers = 99,
            contextSize = 2048,
            threads = 4,
            embeddingMode = false,
        )
        assertTrue(ok)
        assertTrue(bridge.isLoaded())
        assertEquals("/tmp/fake.gguf", bridge.getCurrentModelPath())

        bridge.unload()
        assertFalse(bridge.isLoaded())
        assertNull(bridge.getCurrentModelPath())
    }

    @Test
    fun `versionString returns stub identifier when JNI unavailable`() {
        val bridge = LlamaCppBridge()
        // In JVM tests, JNI isn't loadable, so the Kotlin fallback is returned.
        assertEquals("llama.cpp-stub-android-0.1", bridge.versionString())
    }

    @Test
    fun `completePrompt returns null when not loaded`() {
        val bridge = LlamaCppBridge()
        // No loadModel call -- bridge stays unloaded.
        val result = bridge.completePrompt(
            prompt = "hello",
            maxTokens = 8,
            temperature = 0.7f,
            topP = 0.9f,
        )
        assertNull(result)
    }

    @Test
    fun `completePrompt returns null on JVM fallback even after loadModel`() {
        val bridge = LlamaCppBridge()
        val ok = bridge.loadModel(
            path = "/tmp/fake.gguf",
            mmprojPath = null,
            gpuLayers = 99,
            contextSize = 2048,
            threads = 4,
            embeddingMode = false,
        )
        // On JVM (no .so), the existing fallback returns ok=true.
        assertTrue(ok)
        assertTrue(bridge.isLoaded())
        // But completePrompt's UnsatisfiedLinkError catch returns null.
        val result = bridge.completePrompt("hi", 4, 0.0f, 1.0f)
        assertNull(result)
    }
}
