package co.deepvoiceai.bridge.shared.core.pairing

import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * LAN-pairing handshake helpers (Kotlin mirror of
 * `@dvai-bridge/core/src/pairing/handshake.ts`).
 *
 * The first time Device A wants to offload to Device B over the LAN,
 * A POSTs `/v1/dvai/handshake` to B with its identity + a nonce. B
 * surfaces a UI prompt to the user; on approve, B generates a 256-bit
 * pairing key and returns it. From then on, A includes
 * `X-DVAI-Pairing: HMAC-SHA256(pairingKey, body)` on every offload
 * request to B.
 *
 * All keys + signatures use base64-url encoding, no padding.
 *
 * Implementation note: HMAC is via `javax.crypto.Mac` — we don't pull
 * in BouncyCastle since AndroidKeyStore + the platform Mac provider
 * already cover SHA-256 on every supported API level (24+).
 */
object PairingHandshake {
    /** Generate a fresh 256-bit pairing key (base64-url encoded). */
    fun generatePairingKey(): String {
        val bytes = ByteArray(32)
        SecureRandom().nextBytes(bytes)
        return base64UrlEncode(bytes)
    }

    /** Generate a fresh 128-bit nonce for a handshake request. */
    fun generateNonce(): String {
        val bytes = ByteArray(16)
        SecureRandom().nextBytes(bytes)
        return base64UrlEncode(bytes)
    }

    /**
     * HMAC-SHA256(key, message). Used to sign offload requests so the
     * peer can verify they came from a paired device.
     */
    fun signHmac(pairingKey: String, message: String): String {
        val keyBytes = decodeBase64UrlBytes(pairingKey)
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(keyBytes, "HmacSHA256"))
        val sig = mac.doFinal(message.toByteArray(Charsets.UTF_8))
        return base64UrlEncode(sig)
    }

    /** Verify an HMAC. Returns true on match (constant-time-ish). */
    fun verifyHmac(pairingKey: String, message: String, signature: String): Boolean {
        val expected = signHmac(pairingKey, message)
        return constantTimeEquals(expected, signature)
    }

    /**
     * Compose the canonical message that gets HMAC-signed for a
     * peer-to-peer offload request. The peer recomputes the same
     * string and verifies.
     *
     * Format: `${nonce}\n${method}\n${path}\n${bodyHash}` — bodyHash
     * is the hex-encoded SHA-256 of the request body bytes (or 64
     * zero-bytes for a missing body). Method is uppercased for
     * canonicalization.
     */
    fun composeSignedMessage(
        nonce: String,
        method: String,
        path: String,
        body: String?,
    ): String {
        val bodyHash = if (body != null) sha256Hex(body) else "0".repeat(64)
        return "$nonce\n${method.uppercase()}\n$path\n$bodyHash"
    }

    private fun sha256Hex(input: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val bytes = digest.digest(input.toByteArray(Charsets.UTF_8))
        val sb = StringBuilder(bytes.size * 2)
        for (b in bytes) {
            val v = b.toInt() and 0xff
            sb.append(HEX[v shr 4]).append(HEX[v and 0x0f])
        }
        return sb.toString()
    }

    private val HEX = "0123456789abcdef".toCharArray()

    internal fun base64UrlEncode(bytes: ByteArray): String {
        val sb = StringBuilder()
        val b64 = java.util.Base64.getEncoder().encodeToString(bytes)
        for (c in b64) {
            when (c) {
                '+' -> sb.append('-')
                '/' -> sb.append('_')
                '=' -> Unit
                else -> sb.append(c)
            }
        }
        return sb.toString()
    }

    internal fun decodeBase64UrlBytes(s: String): ByteArray {
        val sb = StringBuilder(s.length + 4)
        for (c in s) {
            when (c) {
                '-' -> sb.append('+')
                '_' -> sb.append('/')
                else -> sb.append(c)
            }
        }
        while (sb.length % 4 != 0) sb.append('=')
        return java.util.Base64.getDecoder().decode(sb.toString())
    }

    private fun constantTimeEquals(a: String, b: String): Boolean {
        if (a.length != b.length) return false
        var diff = 0
        for (i in a.indices) {
            diff = diff or (a[i].code xor b[i].code)
        }
        return diff == 0
    }
}
