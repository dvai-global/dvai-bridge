package co.deepvoiceai.bridge.shared.core.capability

import androidx.test.core.app.ApplicationProvider
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Unit tests for the JSON-on-disk [CapabilityCache] adapter. Uses
 * Robolectric for `Context.cacheDir` — same approach the existing
 * shared-core HTTP tests use for context-dependent code.
 */
@RunWith(RobolectricTestRunner::class)
class CapabilityCacheTest {

    private val ctx = ApplicationProvider.getApplicationContext<android.content.Context>()
    private val cache = CapabilityCache(ctx)

    @After
    fun cleanup() {
        cache.clear()
    }

    @Test
    fun `empty cache returns null on get`() {
        cache.clear()
        val score = cache.get(CapabilityCacheKey("model-x", "3.0.0"))
        assertNull(score)
    }

    @Test
    fun `set then get round-trips`() {
        val score = CapabilityScore(
            modelId = "qwen-1.5b",
            deviceId = "test-device",
            libraryVersion = "3.0.0",
            tokPerSec = 28.4,
            source = ScoreSource.PROBE,
            measuredAt = 1_700_000_000_000L,
        )
        cache.set(score)
        val got = cache.get(CapabilityCacheKey("qwen-1.5b", "3.0.0"))
        assertNotNull(got)
        assertEquals(28.4, got!!.tokPerSec, 0.0001)
        assertEquals("test-device", got.deviceId)
        assertEquals(ScoreSource.PROBE, got.source)
    }

    @Test
    fun `library version is part of the key`() {
        val s1 = CapabilityScore("m", "d", "3.0.0", 10.0, ScoreSource.HEURISTIC, 1L)
        val s2 = CapabilityScore("m", "d", "3.1.0", 20.0, ScoreSource.HEURISTIC, 2L)
        cache.set(s1)
        cache.set(s2)
        assertEquals(10.0, cache.get(CapabilityCacheKey("m", "3.0.0"))!!.tokPerSec, 0.0001)
        assertEquals(20.0, cache.get(CapabilityCacheKey("m", "3.1.0"))!!.tokPerSec, 0.0001)
    }

    @Test
    fun `list returns all entries`() {
        cache.set(CapabilityScore("a", "d", "3.0.0", 1.0, ScoreSource.PROBE, 1L))
        cache.set(CapabilityScore("b", "d", "3.0.0", 2.0, ScoreSource.PROBE, 2L))
        val all = cache.list()
        assertEquals(2, all.size)
    }

    @Test
    fun `clear empties the cache`() {
        cache.set(CapabilityScore("x", "d", "3.0.0", 99.0, ScoreSource.HEURISTIC, 0L))
        assertNotNull(cache.get(CapabilityCacheKey("x", "3.0.0")))
        cache.clear()
        assertNull(cache.get(CapabilityCacheKey("x", "3.0.0")))
    }

    @Test
    fun `cachePath is under cacheDir`() {
        val p = cache.cachePath()
        assertTrue("expected dvai-bridge segment in $p", p.contains("dvai-bridge"))
        assertTrue("expected capability.json in $p", p.endsWith("capability.json"))
    }

    @Test
    fun `DeviceID generate produces base64-url string`() {
        val id = DeviceID.generate()
        assertTrue("got: $id", id.matches(Regex("^[A-Za-z0-9_-]+$")))
        assertTrue("expected length >= 20, got ${id.length}", id.length >= 20)
    }

    @Test
    fun `DeviceID get is stable across calls`() {
        val a = DeviceID.get(ctx)
        val b = DeviceID.get(ctx)
        assertEquals(a, b)
    }

    @Test
    fun `DeviceID reset produces a fresh id`() {
        val a = DeviceID.get(ctx)
        val b = DeviceID.reset(ctx)
        assertTrue("reset should be different from current — got $a == $b", a != b)
    }
}
