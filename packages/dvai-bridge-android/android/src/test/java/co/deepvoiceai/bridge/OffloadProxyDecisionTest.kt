package co.deepvoiceai.bridge

import co.deepvoiceai.bridge.shared.core.discovery.Peer
import co.deepvoiceai.bridge.shared.core.discovery.PeerSource
import co.deepvoiceai.bridge.shared.core.offload.OffloadConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * v3.2 — pre-routing decision logic.
 *
 * Mirrors `packages/dvai-bridge-core/src/__tests__/offload-decide.test.ts`
 * for the canonical TS [decide] function. This test exercises the
 * Kotlin port living inside [OffloadProxy] (private; exposed as
 * `internal` for testing).
 *
 * Doesn't bind a server — only constructs an OffloadProxy and calls
 * the route-decision function with synthetic peers. No HTTP, no
 * Ktor lifecycle, fast.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class OffloadProxyDecisionTest {

    private fun makeProxy(
        backendBaseUrl: String? = "http://127.0.0.1:38983",
        offloadEnabled: Boolean = true,
        minLocalCapability: Double = 10.0,
    ) = OffloadProxy(
        backendBaseUrl = backendBaseUrl,
        offloadConfig = OffloadConfig(
            enabled = offloadEnabled,
            minLocalCapability = minLocalCapability,
        ),
        pairingPolicy = null,
        discovery = null,
        appId = "test.app",
        selfDeviceId = "test-self-device",
    )

    private fun peer(
        deviceId: String,
        modelScore: Map<String, Double>,
        loadedModels: List<String> = emptyList(),
    ) = Peer(
        deviceId = deviceId,
        deviceName = "$deviceId-name",
        dvaiVersion = "3.2.0",
        baseUrl = "http://10.0.0.1:38883",
        loadedModels = loadedModels,
        capability = modelScore,
        via = PeerSource.MDNS,
    )

    /* ------------------------------------------------------------------ */
    /* pickBestPeer                                                       */
    /* ------------------------------------------------------------------ */

    @Test
    fun `pickBestPeer returns null when no peers`() {
        val proxy = makeProxy()
        assertNull(proxy.pickBestPeer(emptyList(), "model-a"))
    }

    @Test
    fun `pickBestPeer prefers higher score`() {
        val proxy = makeProxy()
        val a = peer("a", mapOf("model-a" to 5.0))
        val b = peer("b", mapOf("model-a" to 30.0))
        val c = peer("c", mapOf("model-a" to 12.0))
        val best = proxy.pickBestPeer(listOf(a, b, c), "model-a")
        assertEquals("b", best?.peer?.deviceId)
    }

    @Test
    fun `pickBestPeer prefers peer with model already loaded`() {
        val proxy = makeProxy()
        val notLoaded = peer("a", mapOf("model-a" to 30.0))
        val loaded = peer("b", mapOf("model-a" to 20.0), loadedModels = listOf("model-a"))
        val best = proxy.pickBestPeer(listOf(notLoaded, loaded), "model-a")
        assertEquals("b", best?.peer?.deviceId)
        assertTrue(best!!.hasModel)
    }

    @Test
    fun `pickBestPeer skips peers with zero score for the model`() {
        val proxy = makeProxy()
        val none = peer("a", mapOf("other" to 100.0))
        val zero = peer("b", mapOf("model-a" to 0.0))
        assertNull(proxy.pickBestPeer(listOf(none, zero), "model-a"))
    }

    /* ------------------------------------------------------------------ */
    /* decideRoute                                                        */
    /* ------------------------------------------------------------------ */

    private val emptyHeaders = emptyMap<String, String>()
    private fun headers(vararg pairs: Pair<String, String>) = pairs.toMap()

    @Test
    fun `decideRoute non-chat-completion path goes Local`() {
        val proxy = makeProxy()
        val decision = proxy.decideRoute("/v1/embeddings", ByteArray(0), emptyHeaders)
        assertTrue(
            "expected Local, got $decision",
            decision is OffloadProxy.RouteDecision.Local,
        )
    }

    @Test
    fun `decideRoute non-chat-completion with no backend gives NoCapableDevice`() {
        val proxy = makeProxy(backendBaseUrl = null)
        val decision = proxy.decideRoute("/v1/embeddings", ByteArray(0), emptyHeaders)
        assertTrue(decision is OffloadProxy.RouteDecision.NoCapableDevice)
    }

    @Test
    fun `decideRoute chat-completion + offload disabled goes Local`() {
        val proxy = makeProxy(offloadEnabled = false)
        val decision = proxy.decideRoute(
            "/v1/chat/completions",
            """{"model":"m","stream":false}""".toByteArray(),
            emptyHeaders,
        )
        assertTrue(decision is OffloadProxy.RouteDecision.Local)
    }

    @Test
    fun `decideRoute X-DVAI-Offload never forces local even with peer available`() {
        val proxy = makeProxy()
        val decision = proxy.decideRoute(
            "/v1/chat/completions",
            """{"model":"m"}""".toByteArray(),
            headers("x-dvai-offload" to "never"),
        )
        assertTrue(decision is OffloadProxy.RouteDecision.Local)
    }
}
