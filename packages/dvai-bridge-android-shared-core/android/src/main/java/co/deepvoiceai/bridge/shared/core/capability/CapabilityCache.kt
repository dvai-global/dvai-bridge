package co.deepvoiceai.bridge.shared.core.capability

import android.content.Context
import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json

/**
 * Persistent capability-score cache backed by a single JSON file under
 * `applicationContext.cacheDir/dvai-bridge/capability.json`. Mirrors
 * the `CapabilityCache` interface from `@dvai-bridge/core`.
 *
 * Thread-safety: all read/write is synchronized via the instance lock
 * since the file is shared by the whole process. Cross-process
 * concurrency isn't a concern — only one DVAIBridge runs per app.
 */
class CapabilityCache(context: Context) {
    private val cacheRoot: File =
        File(context.applicationContext.cacheDir, "dvai-bridge").also {
            if (!it.exists()) it.mkdirs()
        }
    private val file: File = File(cacheRoot, "capability.json")
    private val json = Json { ignoreUnknownKeys = true; prettyPrint = true }
    private val lock = Any()

    @Serializable
    private data class Persisted(
        val scores: Map<String, CapabilityScore> = emptyMap(),
    )

    private fun load(): MutableMap<String, CapabilityScore> = synchronized(lock) {
        if (!file.exists()) return mutableMapOf()
        return try {
            val raw = file.readText(Charsets.UTF_8)
            val parsed = json.decodeFromString(Persisted.serializer(), raw)
            parsed.scores.toMutableMap()
        } catch (_: Throwable) {
            // Corrupt cache — start fresh. Next save() overwrites.
            mutableMapOf()
        }
    }

    private fun save(scores: Map<String, CapabilityScore>) = synchronized(lock) {
        try {
            file.writeText(
                json.encodeToString(Persisted.serializer(), Persisted(scores)),
                Charsets.UTF_8,
            )
        } catch (_: Throwable) {
            // Best-effort. Next save() retries.
        }
    }

    private fun keyOf(k: CapabilityCacheKey): String = "${k.libraryVersion}::${k.modelId}"

    fun get(key: CapabilityCacheKey): CapabilityScore? = load()[keyOf(key)]

    fun set(score: CapabilityScore) {
        synchronized(lock) {
            val map = load()
            map[keyOf(CapabilityCacheKey(score.modelId, score.libraryVersion))] = score
            save(map)
        }
    }

    fun list(): List<CapabilityScore> = load().values.toList()

    fun clear() {
        synchronized(lock) {
            if (file.exists()) file.delete()
        }
    }

    /** Path on disk — exposed for diagnostics + tests. */
    fun cachePath(): String = file.absolutePath
}
