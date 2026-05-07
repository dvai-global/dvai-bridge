package co.deepvoiceai.bridge.shared.core.pairing

import android.content.Context
import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Persistent pairing store (Kotlin mirror of `NodeFsPairingStore`
 * from `@westenets/dvai-bridge-core/src/pairing/store.ts`). Backed by
 * a single JSON file under
 * `applicationContext.cacheDir/dvai-bridge/pairings.json`.
 */
class PairingStore(context: Context) {
    private val cacheRoot: File =
        File(context.applicationContext.cacheDir, "dvai-bridge").also {
            if (!it.exists()) it.mkdirs()
        }
    private val file: File = File(cacheRoot, "pairings.json")
    private val json = Json { ignoreUnknownKeys = true; prettyPrint = true }
    private val lock = Any()

    @Serializable
    private data class Persisted(val pairings: Map<String, Pairing> = emptyMap())

    private fun load(): MutableMap<String, Pairing> = synchronized(lock) {
        if (!file.exists()) return mutableMapOf()
        return try {
            val raw = file.readText(Charsets.UTF_8)
            val parsed = json.decodeFromString(Persisted.serializer(), raw)
            parsed.pairings.toMutableMap()
        } catch (_: Throwable) {
            mutableMapOf()
        }
    }

    private fun save(map: Map<String, Pairing>) = synchronized(lock) {
        try {
            file.writeText(
                json.encodeToString(Persisted.serializer(), Persisted(map)),
                Charsets.UTF_8,
            )
        } catch (_: Throwable) {
            // best-effort
        }
    }

    fun get(peerDeviceId: String): Pairing? = load()[peerDeviceId]

    fun set(p: Pairing) {
        synchronized(lock) {
            val map = load()
            map[p.peerDeviceId] = p
            save(map)
        }
    }

    fun list(): List<Pairing> = load().values.toList()

    fun remove(peerDeviceId: String) {
        synchronized(lock) {
            val map = load()
            map.remove(peerDeviceId)
            save(map)
        }
    }

    fun clear() {
        synchronized(lock) {
            if (file.exists()) file.delete()
        }
    }

    /** Path on disk — exposed for diagnostics + tests. */
    fun storePath(): String = file.absolutePath
}
