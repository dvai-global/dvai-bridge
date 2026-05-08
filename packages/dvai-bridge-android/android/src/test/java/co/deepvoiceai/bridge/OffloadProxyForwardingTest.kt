package co.deepvoiceai.bridge

import co.deepvoiceai.bridge.shared.core.discovery.Peer
import co.deepvoiceai.bridge.shared.core.discovery.PeerSource
import co.deepvoiceai.bridge.shared.core.offload.OffloadConfig
import co.deepvoiceai.bridge.shared.core.pairing.Pairing
import co.deepvoiceai.bridge.shared.core.pairing.PairingPolicy
import co.deepvoiceai.bridge.shared.core.pairing.PairingSource
import co.deepvoiceai.bridge.shared.core.pairing.PairingStore
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.util.concurrent.TimeUnit

/**
 * v3.2 — full-loop integration test for [OffloadProxy].
 *
 * Spins up two [MockWebServer] instances inside the JVM:
 *
 *   - `backend` — stands in for the native backend's loopback HTTP
 *     server. Always replies with a JSON body containing
 *     `{"served_by":"backend"}` so tests can assert "did the proxy
 *     forward to here".
 *
 *   - `peer`    — stands in for a remote peer that the proxy might
 *     forward to. Replies with `{"served_by":"peer"}`.
 *
 * The OffloadProxy is constructed with the peerProvider lambda
 * pointing at a fixed `Peer` whose baseUrl is `peer`'s URL. Tests
 * make a real OkHttp request to the proxy's bound port and then
 * inspect:
 *
 *   - which MockWebServer received a request (`takeRequest()` blocks
 *     for up to 1s)
 *   - the response body so we can tell which path executed
 *   - the request headers received by the peer (HMAC signature
 *     headers should be present on offload-routed requests)
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class OffloadProxyForwardingTest {

    private lateinit var backend: MockWebServer
    private lateinit var peer: MockWebServer
    private val client = OkHttpClient.Builder()
        .callTimeout(5, TimeUnit.SECONDS)
        .build()

    private val pairingKey = "test-pairing-key-32-bytes-hex-padding"
    private val peerDeviceId = "peer-device-id"

    @Before
    fun setup() {
        backend = MockWebServer().apply { start() }
        peer = MockWebServer().apply { start() }
    }

    @After
    fun teardown() {
        backend.shutdown()
        peer.shutdown()
    }

    private fun makeProxy(
        backendBaseUrlOverride: String? = backend.url("/").toString().trimEnd('/'),
        offloadEnabled: Boolean = true,
        peers: List<Peer> = emptyList(),
        pairingPolicy: PairingPolicy? = null,
        minLocalCapability: Double = 10.0,
    ): OffloadProxy = OffloadProxy(
        backendBaseUrl = backendBaseUrlOverride,
        offloadConfig = OffloadConfig(
            enabled = offloadEnabled,
            minLocalCapability = minLocalCapability,
        ),
        pairingPolicy = pairingPolicy,
        peerProvider = { peers },
        appId = "co.test.app",
        selfDeviceId = "self-device-id",
    )

    private fun fakePeer(
        scoreForModel: Double = 30.0,
        modelId: String = "test-model",
    ) = Peer(
        deviceId = peerDeviceId,
        deviceName = "test-peer",
        dvaiVersion = "3.2.0",
        baseUrl = peer.url("/").toString().trimEnd('/'),
        loadedModels = listOf(modelId),
        capability = mapOf(modelId to scoreForModel),
        via = PeerSource.MDNS,
    )

    /* ------------------------------------------------------------------ */
    /* Local-only path                                                    */
    /* ------------------------------------------------------------------ */

    @Test
    fun `chat-completion forwards to backend when no peers + offload disabled`() {
        backend.enqueue(
            MockResponse()
                .setResponseCode(200)
                .setHeader("Content-Type", "application/json")
                .setBody("""{"served_by":"backend"}"""),
        )

        val proxy = makeProxy(offloadEnabled = false)
        val proxyPort = proxy.start(basePort = freePort(), maxAttempts = 8)
        try {
            val resp = postJson("http://127.0.0.1:$proxyPort/v1/chat/completions", """{"model":"m"}""")
            assertEquals(200, resp.code)
            assertTrue(resp.body!!.contains(""""served_by":"backend""""))
        } finally {
            proxy.stop()
        }

        val recorded = backend.takeRequest(1, TimeUnit.SECONDS)
        assertNotNull("backend should have received exactly one request", recorded)
        assertEquals("/v1/chat/completions", recorded!!.path)

        // No request should hit the peer.
        assertNull(peer.takeRequest(100, TimeUnit.MILLISECONDS))
    }

    /* ------------------------------------------------------------------ */
    /* Offload path — `prefer` (default) routes to peer when score high   */
    /* ------------------------------------------------------------------ */

    @Test
    fun `chat-completion forwards to peer when offload prefer + peer score above threshold`() {
        peer.enqueue(
            MockResponse()
                .setResponseCode(200)
                .setHeader("Content-Type", "application/json")
                .setBody("""{"served_by":"peer"}"""),
        )

        val proxy = makeProxy(
            peers = listOf(fakePeer(scoreForModel = 50.0)),
            pairingPolicy = pairingPolicyWithKey(),
            minLocalCapability = 10.0,
        )
        val proxyPort = proxy.start(basePort = freePort(), maxAttempts = 8)
        try {
            val resp = postJson(
                "http://127.0.0.1:$proxyPort/v1/chat/completions",
                """{"model":"test-model"}""",
            )
            assertEquals(200, resp.code)
            assertTrue(resp.body!!.contains(""""served_by":"peer""""))
        } finally {
            proxy.stop()
        }

        // Peer received it; backend did not.
        val peerReq = peer.takeRequest(1, TimeUnit.SECONDS)
        assertNotNull("peer should have received the offloaded request", peerReq)
        assertEquals("/v1/chat/completions", peerReq!!.path)

        // Identity headers must be present on peer-bound forwards.
        assertEquals("self-device-id", peerReq.getHeader("X-DVAI-Peer-Device-Id"))
        assertEquals("co.test.app", peerReq.getHeader("X-DVAI-App-Id"))
        assertNotNull(peerReq.getHeader("X-DVAI-Nonce"))
        assertNotNull(peerReq.getHeader("X-DVAI-Signature"))
        assertEquals("1", peerReq.getHeader("X-DVAI-Forwarded"))

        assertNull(backend.takeRequest(100, TimeUnit.MILLISECONDS))
    }

    /* ------------------------------------------------------------------ */
    /* `never` header forces local even with peers                        */
    /* ------------------------------------------------------------------ */

    @Test
    fun `X-DVAI-Offload never forces local even with strong peer`() {
        backend.enqueue(
            MockResponse()
                .setResponseCode(200)
                .setHeader("Content-Type", "application/json")
                .setBody("""{"served_by":"backend"}"""),
        )

        val proxy = makeProxy(
            peers = listOf(fakePeer(scoreForModel = 100.0)),
            pairingPolicy = pairingPolicyWithKey(),
        )
        val proxyPort = proxy.start(basePort = freePort(), maxAttempts = 8)
        try {
            val resp = postJson(
                "http://127.0.0.1:$proxyPort/v1/chat/completions",
                """{"model":"test-model"}""",
                extraHeaders = mapOf("X-DVAI-Offload" to "never"),
            )
            assertEquals(200, resp.code)
            assertTrue(resp.body!!.contains(""""served_by":"backend""""))
        } finally {
            proxy.stop()
        }

        assertNotNull(backend.takeRequest(1, TimeUnit.SECONDS))
        assertNull(peer.takeRequest(100, TimeUnit.MILLISECONDS))
    }

    /* ------------------------------------------------------------------ */
    /* `require` header without peers → 503                               */
    /* ------------------------------------------------------------------ */

    @Test
    fun `X-DVAI-Offload require with no peers returns no_capable_device`() {
        val proxy = makeProxy(peers = emptyList())
        val proxyPort = proxy.start(basePort = freePort(), maxAttempts = 8)
        try {
            val resp = postJson(
                "http://127.0.0.1:$proxyPort/v1/chat/completions",
                """{"model":"test-model"}""",
                extraHeaders = mapOf("X-DVAI-Offload" to "require"),
            )
            assertEquals(503, resp.code)
            assertTrue(resp.body!!.contains("no_capable_device"))
        } finally {
            proxy.stop()
        }

        assertNull(backend.takeRequest(100, TimeUnit.MILLISECONDS))
        assertNull(peer.takeRequest(100, TimeUnit.MILLISECONDS))
    }

    /* ------------------------------------------------------------------ */
    /* Offload-only mode (no backend) + no peers → 503                    */
    /* ------------------------------------------------------------------ */

    @Test
    fun `offload-only mode with no peers returns no_local_backend`() {
        val proxy = makeProxy(
            backendBaseUrlOverride = null,
            peers = emptyList(),
        )
        val proxyPort = proxy.start(basePort = freePort(), maxAttempts = 8)
        try {
            val resp = postJson(
                "http://127.0.0.1:$proxyPort/v1/chat/completions",
                """{"model":"test-model"}""",
            )
            assertEquals(503, resp.code)
            // either no_local_backend (no offload) or no_capable_device (offload but no peers)
            assertTrue(
                "expected 503 with structured error, got: ${resp.body}",
                resp.body!!.contains("no_local_backend") || resp.body.contains("no_capable_device"),
            )
        } finally {
            proxy.stop()
        }
    }

    /* ------------------------------------------------------------------ */
    /* Helpers                                                            */
    /* ------------------------------------------------------------------ */

    private data class HttpResponseSnapshot(val code: Int, val body: String?)

    /** Ask the OS for a free port, then close the socket so the proxy
     *  can bind it on the next syscall. There's a tiny race window
     *  but it's acceptable for unit tests. */
    private fun freePort(): Int {
        val socket = java.net.ServerSocket(0)
        val port = socket.localPort
        socket.close()
        return port
    }

    private fun postJson(
        url: String,
        body: String,
        extraHeaders: Map<String, String> = emptyMap(),
    ): HttpResponseSnapshot {
        val req = Request.Builder()
            .url(url)
            .post(body.toRequestBody("application/json".toMediaType()))
            .apply { for ((k, v) in extraHeaders) header(k, v) }
            .build()
        return client.newCall(req).execute().use {
            HttpResponseSnapshot(it.code, it.body?.string())
        }
    }

    private fun pairingPolicyWithKey(): PairingPolicy {
        // PairingStore writes to context.cacheDir/dvai-bridge — Robolectric
        // provides a real cache dir. Pre-seed a pairing for our fake peer
        // so the proxy's HMAC sign step finds a key.
        val ctx = RuntimeEnvironment.getApplication()
        val store = PairingStore(ctx)
        store.clear()
        store.set(
            Pairing(
                peerDeviceId = peerDeviceId,
                peerDeviceName = "test-peer",
                pairingKey = pairingKey,
                pairedAt = System.currentTimeMillis(),
                lastUsedAt = System.currentTimeMillis(),
                via = PairingSource.LAN_HANDSHAKE,
            ),
        )
        return PairingPolicy(store)
    }

}
