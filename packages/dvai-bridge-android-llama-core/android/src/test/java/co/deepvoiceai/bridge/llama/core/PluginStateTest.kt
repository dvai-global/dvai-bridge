package co.deepvoiceai.bridge.llama.core

import com.getcapacitor.JSObject
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
            state.start(JSObject())
            fail("Expected exception")
        } catch (e: IllegalArgumentException) {
            assertTrue(e.message!!.contains("modelPath is required"))
        }
    }

    @Test
    fun `start fails when modelPath empty`() = runBlocking {
        val state = PluginState().also { states.add(it) }
        try {
            state.start(JSObject().apply { put("modelPath", "") })
            fail("Expected exception")
        } catch (e: IllegalArgumentException) {
            // expected
        }
    }

    @Test
    fun `statusInfo reports not running initially`() {
        val state = PluginState().also { states.add(it) }
        val info = state.statusInfo()
        assertEquals(false, info.getBoolean("running"))
    }

    @Test
    fun `start binds server and reports baseUrl`() = runBlocking {
        val state = PluginState().also { states.add(it) }
        val opts = JSObject().apply {
            put("modelPath", "/tmp/fake.gguf")
            put("httpBasePort", 39300)
            put("httpMaxPortAttempts", 4)
        }
        val result = state.start(opts)
        assertEquals("llama", result.getString("backend"))
        assertEquals("/tmp/fake.gguf", result.getString("modelId"))
        val port = result.getInteger("port")!!
        assertTrue(port in 39300..39303)
        assertEquals("http://127.0.0.1:$port/v1", result.getString("baseUrl"))

        state.stop()
        val info = state.statusInfo()
        assertEquals(false, info.getBoolean("running"))
    }

    @Test
    fun `restart replaces previous run`() = runBlocking {
        val state = PluginState().also { states.add(it) }
        state.start(JSObject().apply {
            put("modelPath", "/tmp/fake1.gguf")
            put("httpBasePort", 39310)
            put("httpMaxPortAttempts", 4)
        })
        val result2 = state.start(JSObject().apply {
            put("modelPath", "/tmp/fake2.gguf")
            put("httpBasePort", 39320)
            put("httpMaxPortAttempts", 4)
        })
        assertEquals("/tmp/fake2.gguf", result2.getString("modelId"))
    }
}
