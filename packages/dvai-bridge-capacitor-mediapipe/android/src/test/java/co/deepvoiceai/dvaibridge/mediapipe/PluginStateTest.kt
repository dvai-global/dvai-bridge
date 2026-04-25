package co.deepvoiceai.dvaibridge.mediapipe

import com.getcapacitor.JSObject
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

/**
 * Negative-path JVM tests for [PluginState]. A happy-path `start` test is
 * intentionally NOT included here — booting [MediaPipeBridge] requires a
 * real `.task` model bundle on disk, and there is no fake-bridge seam at the
 * PluginState layer. Phase 1G CI hardening can add an injectable factory
 * if a happy-path test is later judged worth the refactor.
 *
 * The four tests below cover:
 *  - Initial status reports `running:false`.
 *  - Missing `modelPath` raises [IllegalArgumentException] with a clear msg.
 *  - Empty `modelPath` raises [IllegalArgumentException] with the same msg.
 *  - Idle-state `stop` is a no-op (idempotent — safe before any start).
 *
 * Robolectric is required because [PluginState.start] takes an Android
 * [android.content.Context] (delegated to [MediaPipeBridge]); for the
 * validation-failure tests we never reach the bridge constructor, so the
 * context is only used to construct the call — not to load any native code.
 */
@RunWith(RobolectricTestRunner::class)
class PluginStateTest {
    private val states = mutableListOf<PluginState>()
    private val context: android.content.Context get() = RuntimeEnvironment.getApplication()

    @After
    fun tearDown() = runBlocking {
        states.forEach { runCatching { it.stop() } }
        states.clear()
    }

    @Test
    fun `statusInfo reports not running initially`() {
        val state = PluginState().also { states.add(it) }
        val info = state.statusInfo()
        assertEquals(false, info.getBoolean("running"))
    }

    @Test
    fun `start fails when modelPath missing`() = runBlocking {
        val state = PluginState().also { states.add(it) }
        try {
            state.start(JSObject(), context)
            fail("Expected IllegalArgumentException")
        } catch (e: IllegalArgumentException) {
            assertTrue(
                "message should mention 'modelPath is required' but was: ${e.message}",
                e.message!!.contains("modelPath is required"),
            )
        }
    }

    @Test
    fun `start fails when modelPath empty`() = runBlocking {
        val state = PluginState().also { states.add(it) }
        try {
            state.start(JSObject().apply { put("modelPath", "") }, context)
            fail("Expected IllegalArgumentException")
        } catch (e: IllegalArgumentException) {
            assertTrue(
                "message should mention 'modelPath is required' but was: ${e.message}",
                e.message!!.contains("modelPath is required"),
            )
        }
    }

    @Test
    fun `stop before start is idempotent`() = runBlocking {
        val state = PluginState().also { states.add(it) }
        // Should not throw — calling stop() on an idle state is a no-op.
        state.stop()
        val info = state.statusInfo()
        assertEquals(false, info.getBoolean("running"))
    }
}
