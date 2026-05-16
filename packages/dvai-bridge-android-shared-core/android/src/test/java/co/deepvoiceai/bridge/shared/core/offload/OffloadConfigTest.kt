package co.deepvoiceai.bridge.shared.core.offload

import co.deepvoiceai.bridge.shared.core.discovery.Peer
import co.deepvoiceai.bridge.shared.core.discovery.PeerSource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Smoke-tests for the [OffloadConfig] data class — defaults match the
 * TS reference at `@dvai-bridge/core/src/offload/types.ts`,
 * and Kotlin `copy(...)` produces independent instances.
 */
class OffloadConfigTest {

    @Test
    fun `defaults match TS reference shape`() {
        val cfg = OffloadConfig()
        assertFalse("offload defaults to disabled", cfg.enabled)
        assertTrue("LAN discovery defaults on (only fires when enabled=true)", cfg.discoverLAN)
        assertEquals(10.0, cfg.minLocalCapability, 0.0001)
        assertNull(cfg.rendezvousUrl)
        assertTrue(cfg.knownPeers.isEmpty())
        assertNull(cfg.onPairingRequest)
        assertNull(cfg.onOffload)
    }

    @Test
    fun `enabling preserves other defaults`() {
        val cfg = OffloadConfig(enabled = true)
        assertTrue(cfg.enabled)
        assertTrue(cfg.discoverLAN)
        assertEquals(10.0, cfg.minLocalCapability, 0.0001)
    }

    @Test
    fun `copy semantics are independent`() {
        val cfg = OffloadConfig(
            enabled = true,
            minLocalCapability = 25.0,
            rendezvousUrl = "wss://rendezvous.example.com",
        )
        val derived = cfg.copy(rendezvousUrl = null)
        assertEquals("wss://rendezvous.example.com", cfg.rendezvousUrl)
        assertNull(derived.rendezvousUrl)
        // Other fields preserved.
        assertEquals(25.0, derived.minLocalCapability, 0.0001)
        assertTrue(derived.enabled)
    }

    @Test
    fun `knownPeers passes through`() {
        val peer = Peer(
            deviceId = "test-peer",
            deviceName = "Test Peer",
            dvaiVersion = "3.0.0",
            baseUrl = "http://10.0.0.5:38883",
            via = PeerSource.STATIC,
        )
        val cfg = OffloadConfig(enabled = true, knownPeers = listOf(peer))
        assertEquals(1, cfg.knownPeers.size)
        assertSame(peer, cfg.knownPeers.first())
    }

    @Test
    fun `onPairingRequest callback stays attached after copy`() {
        var called = false
        val cb: suspend (Peer) -> Boolean = { _ -> called = true; true }
        val cfg = OffloadConfig(enabled = true, onPairingRequest = cb)
        val derived = cfg.copy(minLocalCapability = 5.0)
        assertNotNull(derived.onPairingRequest)
        assertSame(cb, derived.onPairingRequest)
        // Sanity-check: the callback compiles + invokes (called flag flipped).
        kotlinx.coroutines.runBlocking {
            cfg.onPairingRequest!!.invoke(
                Peer(
                    deviceId = "x", deviceName = "x", dvaiVersion = "3.0.0",
                    baseUrl = "http://x", via = PeerSource.STATIC,
                ),
            )
        }
        assertTrue(called)
    }
}
