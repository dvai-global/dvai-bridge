package co.deepvoiceai.bridge.shared.core.discovery

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Tests for [Peer] data + TXT-record (de)serialization. Mirrors the
 * shape used by the TS reference at
 * `@dvai-bridge/core/src/discovery/types.ts`.
 */
class PeerTest {

    @Test
    fun `parsePeerTxt returns null when deviceId missing`() {
        val txt = mapOf(PeerTxtKeys.DVAI_VERSION to "3.0.0")
        assertNull(parsePeerTxt(txt, "http://10.0.0.5:38883"))
    }

    @Test
    fun `parsePeerTxt returns null when version missing`() {
        val txt = mapOf(PeerTxtKeys.DEVICE_ID to "abc")
        assertNull(parsePeerTxt(txt, "http://10.0.0.5:38883"))
    }

    @Test
    fun `parsePeerTxt full record`() {
        val txt = mapOf(
            PeerTxtKeys.DEVICE_ID to "dev-A",
            PeerTxtKeys.DEVICE_NAME to "Pixel 9 Pro",
            PeerTxtKeys.DVAI_VERSION to "3.0.0",
            PeerTxtKeys.MODELS to "qwen-1.5b,gemma-2b",
            PeerTxtKeys.CAPABILITY to "qwen-1.5b:25.5,gemma-2b:18.2",
            PeerTxtKeys.SECURE to "true",
        )
        val peer = parsePeerTxt(txt, "https://10.0.0.5:38883")
        assertNotNull(peer)
        assertEquals("dev-A", peer!!.deviceId)
        assertEquals("Pixel 9 Pro", peer.deviceName)
        assertEquals("3.0.0", peer.dvaiVersion)
        assertEquals(listOf("qwen-1.5b", "gemma-2b"), peer.loadedModels)
        assertEquals(25.5, peer.capability["qwen-1.5b"]!!, 0.0001)
        assertEquals(18.2, peer.capability["gemma-2b"]!!, 0.0001)
        assertTrue(peer.secure)
        assertEquals(PeerSource.MDNS, peer.via)
    }

    @Test
    fun `parsePeerTxt deviceName falls back to deviceId`() {
        val txt = mapOf(
            PeerTxtKeys.DEVICE_ID to "dev-X",
            PeerTxtKeys.DVAI_VERSION to "3.0.0",
        )
        val peer = parsePeerTxt(txt, "http://10.0.0.5:38883")
        assertEquals("dev-X", peer!!.deviceName)
    }

    @Test
    fun `parsePeerTxt secure false default`() {
        val txt = mapOf(
            PeerTxtKeys.DEVICE_ID to "x",
            PeerTxtKeys.DVAI_VERSION to "3.0.0",
        )
        val peer = parsePeerTxt(txt, "http://10.0.0.5:38883")
        assertEquals(false, peer!!.secure)
    }

    @Test
    fun `parsePeerTxt skips malformed capability entries`() {
        val txt = mapOf(
            PeerTxtKeys.DEVICE_ID to "x",
            PeerTxtKeys.DVAI_VERSION to "3.0.0",
            PeerTxtKeys.CAPABILITY to "bad-no-colon,model:not-a-number,good:42.0",
        )
        val peer = parsePeerTxt(txt, "http://10.0.0.5:38883")
        assertEquals(1, peer!!.capability.size)
        assertEquals(42.0, peer.capability["good"]!!, 0.0001)
    }

    @Test
    fun `Peer toTxt round-trips through parsePeerTxt`() {
        val original = Peer(
            deviceId = "dev-Y",
            deviceName = "Tablet",
            dvaiVersion = "3.0.0",
            baseUrl = "http://10.0.0.5:38883",
            loadedModels = listOf("a", "b"),
            capability = mapOf("a" to 10.0, "b" to 20.0),
            via = PeerSource.MDNS,
            secure = false,
        )
        val txt = original.toTxt()
        val parsed = parsePeerTxt(txt, original.baseUrl)
        assertNotNull(parsed)
        assertEquals(original.deviceId, parsed!!.deviceId)
        assertEquals(original.deviceName, parsed.deviceName)
        assertEquals(original.dvaiVersion, parsed.dvaiVersion)
        assertEquals(original.loadedModels, parsed.loadedModels)
        assertEquals(original.capability["a"], parsed.capability["a"])
        assertEquals(original.capability["b"], parsed.capability["b"])
    }

    @Test
    fun `NsdAttrs fromTxt produces UTF-8 byte arrays`() {
        val txt = mapOf("k" to "héllo")
        val attrs = NsdDiscovery.NsdAttrs.fromTxt(txt)
        assertEquals(1, attrs.size)
        // "héllo" UTF-8 = 6 bytes (é = 2 bytes).
        assertEquals(6, attrs["k"]!!.size)
        assertEquals("héllo", String(attrs["k"]!!, Charsets.UTF_8))
    }

    @Test
    fun `service type constant matches spec`() {
        assertEquals("_dvai-bridge._tcp", DVAI_NSD_SERVICE_TYPE)
    }
}
