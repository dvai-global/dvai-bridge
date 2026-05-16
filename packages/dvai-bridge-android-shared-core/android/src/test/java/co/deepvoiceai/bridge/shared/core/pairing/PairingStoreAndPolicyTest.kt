package co.deepvoiceai.bridge.shared.core.pairing

import androidx.test.core.app.ApplicationProvider
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.onSubscription
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Tests for the JSON-on-disk [PairingStore] + the UI-coordination
 * [PairingPolicy]. Mirrors the policy semantics from
 * `@dvai-bridge/core/src/pairing/policy.ts`.
 */
@RunWith(RobolectricTestRunner::class)
class PairingStoreAndPolicyTest {

    private val ctx = ApplicationProvider.getApplicationContext<android.content.Context>()
    private val store = PairingStore(ctx)

    @After
    fun cleanup() {
        store.clear()
    }

    @Test
    fun `set then get round-trips`() {
        val p = Pairing(
            peerDeviceId = "dev-A",
            peerDeviceName = "A",
            pairingKey = PairingHandshake.generatePairingKey(),
            pairedAt = 1L,
            lastUsedAt = 2L,
            via = PairingSource.LAN_HANDSHAKE,
        )
        store.set(p)
        val got = store.get("dev-A")
        assertNotNull(got)
        assertEquals(p.pairingKey, got!!.pairingKey)
        assertEquals(PairingSource.LAN_HANDSHAKE, got.via)
    }

    @Test
    fun `remove deletes by deviceId`() {
        val p = Pairing("dev-B", "B", "k", 0L, 0L, PairingSource.LAN_HANDSHAKE)
        store.set(p)
        store.remove("dev-B")
        assertNull(store.get("dev-B"))
    }

    @Test
    fun `list returns all entries`() {
        store.set(Pairing("a", "A", "k1", 0L, 0L, PairingSource.LAN_HANDSHAKE))
        store.set(Pairing("b", "B", "k2", 0L, 0L, PairingSource.LAN_HANDSHAKE))
        assertEquals(2, store.list().size)
    }

    @Test
    fun `policy denies when no UI subscriber and timeout elapses`() = runBlocking {
        val policy = PairingPolicy(store, requestTimeoutMs = 50L)
        try {
            policy.approveOrFetch("new-dev", "New Device", PairingSource.LAN_HANDSHAKE)
            org.junit.Assert.fail("expected PairingDeniedException")
        } catch (e: PairingDeniedException) {
            assertTrue(e.message!!.contains("denied"))
        }
    }

    @Test
    fun `policy approves when UI says yes`() = runBlocking {
        val policy = PairingPolicy(store, requestTimeoutMs = 5_000L)
        // Use `onSubscription` to deterministically signal that the
        // SharedFlow collector is now registered before triggering the
        // emission. This avoids a fragile sleep-then-emit race.
        val subscribed = CompletableDeferred<Unit>()
        val collector = async {
            policy.requests
                .onSubscription { subscribed.complete(Unit) }
                .first()
                .respond(true)
        }
        subscribed.await()
        val pairing = policy.approveOrFetch("ui-dev", "UI Device", PairingSource.LAN_HANDSHAKE)
        collector.await()
        assertEquals("ui-dev", pairing.peerDeviceId)
        assertNotNull(store.get("ui-dev"))
    }

    @Test
    fun `policy reuses active pairing without re-prompting`() = runBlocking {
        val pre = Pairing(
            peerDeviceId = "known", peerDeviceName = "K",
            pairingKey = PairingHandshake.generatePairingKey(),
            pairedAt = System.currentTimeMillis(),
            lastUsedAt = System.currentTimeMillis(),
            via = PairingSource.LAN_HANDSHAKE,
        )
        store.set(pre)
        val policy = PairingPolicy(store, requestTimeoutMs = 50L)
        val got = policy.approveOrFetch("known", "K", PairingSource.LAN_HANDSHAKE)
        assertEquals(pre.pairingKey, got.pairingKey)
    }

    @Test
    fun `policy expires stale pairings on getActive`() {
        val ancient = Pairing(
            peerDeviceId = "old", peerDeviceName = "O",
            pairingKey = "k",
            pairedAt = 0L,
            lastUsedAt = 0L,
            via = PairingSource.LAN_HANDSHAKE,
        )
        store.set(ancient)
        val policy = PairingPolicy(store, expireAfterDays = 30)
        val got = policy.getActive("old")
        assertNull("expected stale pairing to be expired + removed", got)
        assertNull("store should also have dropped it", store.get("old"))
    }
}
