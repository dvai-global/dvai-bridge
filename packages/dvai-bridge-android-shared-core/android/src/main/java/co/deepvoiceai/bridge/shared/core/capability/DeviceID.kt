package co.deepvoiceai.bridge.shared.core.capability

import android.content.Context
import java.io.File
import java.security.SecureRandom
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Stable per-install device identifier (Kotlin mirror of
 * `@dvai-bridge/core/src/capability/deviceId.ts`).
 *
 * - Generated once on first call, then persisted under
 *   `applicationContext.cacheDir/dvai-bridge/device.json`.
 * - Used to identify THIS device in mDNS TXT records, rendezvous
 *   pairing payloads, and as the key for the capability cache.
 *
 * NOT a privacy hazard: the ID is per-install and per-cache-storage,
 * never tied to user identity. Reinstalling the app or wiping app
 * storage produces a fresh ID — that's the right behaviour.
 */
object DeviceID {
    private const val FILENAME = "device.json"
    private const val CACHE_DIR_NAME = "dvai-bridge"

    @Serializable
    private data class DeviceFile(val deviceId: String)

    private val json = Json { ignoreUnknownKeys = true; prettyPrint = true }

    /**
     * Read the persistent device ID, generating + persisting one if
     * none exists. Safe to call from any thread; the file write
     * is atomic-enough for the per-install lifetime guarantee
     * (single-writer, never concurrent across processes).
     */
    @Synchronized
    fun get(context: Context): String {
        val dir = File(context.applicationContext.cacheDir, CACHE_DIR_NAME)
        if (!dir.exists()) dir.mkdirs()
        val file = File(dir, FILENAME)
        if (file.exists()) {
            try {
                val txt = file.readText(Charsets.UTF_8)
                val parsed = json.decodeFromString(DeviceFile.serializer(), txt)
                if (parsed.deviceId.isNotEmpty()) return parsed.deviceId
            } catch (_: Throwable) {
                // Fall through and regenerate on parse error.
            }
        }
        val fresh = generate()
        try {
            file.writeText(json.encodeToString(DeviceFile.serializer(), DeviceFile(fresh)), Charsets.UTF_8)
        } catch (_: Throwable) {
            // If we can't persist, the caller still gets a valid ID for
            // this process; the next call will try again.
        }
        return fresh
    }

    /**
     * Reset the persisted device ID. Returns the new ID. Mainly for
     * tests + the "forget all paired peers" UI.
     */
    @Synchronized
    fun reset(context: Context): String {
        val dir = File(context.applicationContext.cacheDir, CACHE_DIR_NAME)
        if (!dir.exists()) dir.mkdirs()
        val file = File(dir, FILENAME)
        val fresh = generate()
        file.writeText(json.encodeToString(DeviceFile.serializer(), DeviceFile(fresh)), Charsets.UTF_8)
        return fresh
    }

    /** Generate a 22-char URL-safe random ID. Equivalent to the TS impl. */
    fun generate(): String {
        val bytes = ByteArray(16)
        SecureRandom().nextBytes(bytes)
        return base64UrlEncode(bytes)
    }

    private fun base64UrlEncode(bytes: ByteArray): String {
        val sb = StringBuilder()
        val b64 = java.util.Base64.getEncoder().encodeToString(bytes)
        for (c in b64) {
            when (c) {
                '+' -> sb.append('-')
                '/' -> sb.append('_')
                '=' -> Unit // strip padding
                else -> sb.append(c)
            }
        }
        return sb.toString()
    }
}
