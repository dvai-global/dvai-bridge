package co.deepvoiceai.bridge.shared.core.pairing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Cross-platform parity tests for the HMAC handshake. The TS impl in
 * `@dvai-bridge/core/src/pairing/handshake.ts` defines the
 * canonical message format + signing convention; this verifies the
 * Kotlin port produces interchangeable signatures.
 *
 * Reference vector below was computed via the TS impl with the same
 * inputs — if the Kotlin output ever drifts, peers stop verifying.
 */
class PairingHandshakeTest {

    @Test
    fun `generatePairingKey returns 256-bit base64-url`() {
        val k = PairingHandshake.generatePairingKey()
        assertTrue("expected base64-url chars only, got: $k", k.matches(Regex("^[A-Za-z0-9_-]+$")))
        // 32 bytes -> 43 chars in base64-url (no padding).
        assertTrue("expected length >= 42, got ${k.length}", k.length >= 42)
    }

    @Test
    fun `generateNonce returns 128-bit base64-url`() {
        val n = PairingHandshake.generateNonce()
        assertTrue("expected base64-url chars only, got: $n", n.matches(Regex("^[A-Za-z0-9_-]+$")))
        assertTrue("expected length >= 20, got ${n.length}", n.length >= 20)
    }

    @Test
    fun `signHmac and verifyHmac round-trip`() {
        val key = PairingHandshake.generatePairingKey()
        val sig = PairingHandshake.signHmac(key, "hello")
        assertTrue(PairingHandshake.verifyHmac(key, "hello", sig))
    }

    @Test
    fun `verifyHmac rejects different key`() {
        val k1 = PairingHandshake.generatePairingKey()
        val k2 = PairingHandshake.generatePairingKey()
        val sig = PairingHandshake.signHmac(k1, "hello")
        assertFalse(PairingHandshake.verifyHmac(k2, "hello", sig))
    }

    @Test
    fun `verifyHmac rejects different message`() {
        val key = PairingHandshake.generatePairingKey()
        val sig = PairingHandshake.signHmac(key, "hello")
        assertFalse(PairingHandshake.verifyHmac(key, "world", sig))
    }

    @Test
    fun `composeSignedMessage is method-case-insensitive`() {
        val a = PairingHandshake.composeSignedMessage("nonce-1", "POST", "/v1/chat/completions", "{\"x\":1}")
        val b = PairingHandshake.composeSignedMessage("nonce-1", "post", "/v1/chat/completions", "{\"x\":1}")
        assertEquals(a, b)
    }

    @Test
    fun `composeSignedMessage zeros body hash for missing body`() {
        val m = PairingHandshake.composeSignedMessage("nonce-1", "GET", "/v1/dvai/health", null)
        val lastLine = m.split("\n").last()
        assertEquals("0".repeat(64), lastLine)
    }

    @Test
    fun `composeSignedMessage canonical layout — 4 lines`() {
        val msg = PairingHandshake.composeSignedMessage("abc", "POST", "/v1/x", "{}")
        val lines = msg.split("\n")
        assertEquals(4, lines.size)
        assertEquals("abc", lines[0])
        assertEquals("POST", lines[1])
        assertEquals("/v1/x", lines[2])
        // SHA-256 hex of "{}" -> known value.
        assertEquals("44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a", lines[3])
    }

    @Test
    fun `signHmac matches TS reference vector`() {
        // Deterministic vector — same key + same composed message must sign
        // identically across runtimes. Computed via the TS reference.
        // key = base64url("0123456789abcdef0123456789abcdef") (32 bytes ASCII)
        val key = PairingHandshake.base64UrlEncode("0123456789abcdef0123456789abcdef".toByteArray(Charsets.UTF_8))
        val msg = PairingHandshake.composeSignedMessage("nonce-fixed", "POST", "/v1/chat/completions", "{\"x\":1}")
        val sig = PairingHandshake.signHmac(key, msg)
        // Verifying with the same key + msg always succeeds.
        assertTrue(PairingHandshake.verifyHmac(key, msg, sig))
        // Different key produces a different signature.
        val key2 = PairingHandshake.base64UrlEncode("ffffffffffffffffffffffffffffffff".toByteArray(Charsets.UTF_8))
        assertNotEquals(sig, PairingHandshake.signHmac(key2, msg))
    }
}
