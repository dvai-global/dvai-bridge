package co.deepvoiceai.bridge.llama.core

import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class PluginStateTest {
    private val states = mutableListOf<PluginState>()

    @After
    fun tearDown() = runBlocking {
        states.forEach { runCatching { it.stop() } }
        states.clear()
    }

    @Test
    fun `start fails when modelPath missing`() = runBlocking {
        val state = PluginState().also { states.add(it) }
        try {
            state.start(emptyMap())
            fail("Expected exception")
        } catch (e: IllegalArgumentException) {
            assertTrue(e.message!!.contains("modelPath is required"))
        }
    }

    @Test
    fun `start fails when modelPath empty`() = runBlocking {
        val state = PluginState().also { states.add(it) }
        try {
            state.start(mapOf("modelPath" to ""))
            fail("Expected exception")
        } catch (e: IllegalArgumentException) {
            // expected
        }
    }

    @Test
    fun `statusInfo reports not running initially`() {
        val state = PluginState().also { states.add(it) }
        val info = state.statusInfo()
        assertEquals(false, info["running"])
    }

    @Test
    fun `start binds server and reports baseUrl`() = runBlocking {
        val state = PluginState().also { states.add(it) }
        val opts = mapOf(
            "modelPath" to "/tmp/fake.gguf",
            "httpBasePort" to 39300,
            "httpMaxPortAttempts" to 4,
        )
        val result = state.start(opts)
        assertEquals("llama", result["backend"])
        assertEquals("/tmp/fake.gguf", result["modelId"])
        val port = result["port"] as Int
        assertTrue(port in 39300..39303)
        assertEquals("http://127.0.0.1:$port/v1", result["baseUrl"])

        state.stop()
        val info = state.statusInfo()
        assertEquals(false, info["running"])
    }

    @Test
    fun `restart replaces previous run`() = runBlocking {
        val state = PluginState().also { states.add(it) }
        state.start(mapOf(
            "modelPath" to "/tmp/fake1.gguf",
            "httpBasePort" to 39310,
            "httpMaxPortAttempts" to 4,
        ))
        val result2 = state.start(mapOf(
            "modelPath" to "/tmp/fake2.gguf",
            "httpBasePort" to 39320,
            "httpMaxPortAttempts" to 4,
        ))
        assertEquals("/tmp/fake2.gguf", result2["modelId"])
    }
}
