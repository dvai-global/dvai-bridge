package co.deepvoiceai.dvaibridge.llama

import android.content.Context
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.RandomAccessFile
import java.security.MessageDigest

/**
 * Resumable, sha256-verified model downloader plus cache management.
 *
 * Cache directory layout (per spec §9.2):
 *   - default: `<context.filesDir>/dvai-models/<filename>`
 *   - test override: any caller-supplied `File` (used by unit tests to
 *     keep the real filesDir clean).
 *
 * All public functions are blocking — call from a background thread or
 * a coroutine on `Dispatchers.IO`. The plugin layer wraps this in
 * `scope.launch { ... }` already.
 */
class ModelDownloader(
    private val context: Context?,
    private val cacheDirOverride: File? = null,
    private val httpClient: OkHttpClient = OkHttpClient(),
) {
    sealed class DownloadError(message: String) : Exception(message) {
        class ChecksumMismatch(val expected: String, val got: String) :
            DownloadError("ChecksumMismatchError: expected $expected, got $got")
        class HttpError(val status: Int) : DownloadError("HTTP error $status")
        class Sha256Required : DownloadError("sha256 is required")
        class MissingContext : DownloadError("Context is required when no cache dir override is set")
    }

    // MARK: - Cache dir

    /** Resolve and create the cache directory. */
    fun cacheDir(): File {
        val dir = cacheDirOverride
            ?: context?.let { File(it.filesDir, "dvai-models") }
            ?: throw DownloadError.MissingContext()
        if (!dir.exists()) dir.mkdirs()
        return dir
    }

    // MARK: - List / delete

    /** Enumerate files in the cache dir (skipping `.partial` and dotfiles). */
    fun listCached(): List<CachedModelInfo> {
        val dir = cacheDir()
        val files = dir.listFiles() ?: return emptyList()
        return files
            .filter { it.isFile && !it.name.startsWith(".") && !it.name.endsWith(".partial") }
            .map { f ->
                CachedModelInfo(
                    filename = f.name,
                    path = f.absolutePath,
                    bytes = f.length(),
                    sha256 = sha256OfFile(f),
                )
            }
    }

    fun deleteCached(filename: String) {
        val dir = cacheDir()
        File(dir, filename).takeIf { it.exists() }?.delete()
        File(dir, "$filename.partial").takeIf { it.exists() }?.delete()
    }

    // MARK: - Download

    /**
     * Download `url` into `<cacheDir>/<destFilename>`, resumable + sha256-verified.
     *
     * @param onProgress invoked with (bytesDone, bytesTotal?). Already
     *   debounced internally to ~10/sec; do not throttle again upstream.
     * @return Pair(absolutePath, cached). `cached: true` means the file was
     *   already present with a matching hash and no network request was made.
     */
    fun downloadModel(
        url: String,
        expectedSha256: String,
        destFilename: String,
        headers: Map<String, String>,
        onProgress: (bytesDone: Long, bytesTotal: Long?) -> Unit,
    ): Pair<String, Boolean> {
        if (expectedSha256.isEmpty()) throw DownloadError.Sha256Required()
        val expected = expectedSha256.lowercase()

        val dir = cacheDir()
        val final = File(dir, destFilename)
        val partial = File(dir, "$destFilename.partial")

        // Step 2: cache hit check.
        if (final.exists()) {
            val existing = sha256OfFile(final)
            if (existing == expected) {
                return final.absolutePath to true
            }
            // Step 3: mismatch → delete and fall through.
            final.delete()
        }

        // Step 4: resume / fresh download. Loop guards the oversized-partial
        // restart path: we must exit `response.use { }` (releasing the prior
        // OkHttp connection) BEFORE issuing the new request, otherwise the
        // previous connection sits open during the recursive download.
        var attempt = 0
        while (attempt < 2) {
            val sha = MessageDigest.getInstance("SHA-256")
            var written: Long = 0L

            if (partial.exists()) {
                // Replay existing bytes through the hash so we can resume.
                partial.inputStream().use { ins ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = ins.read(buf)
                        if (n <= 0) break
                        sha.update(buf, 0, n)
                        written += n
                    }
                }
            }

            val reqBuilder = Request.Builder().url(url)
            headers.forEach { (k, v) -> reqBuilder.addHeader(k, v) }
            if (written > 0) reqBuilder.addHeader("Range", "bytes=$written-")

            var restart = false
            httpClient.newCall(reqBuilder.build()).execute().use { resp ->
                // 200 = full body. 206 = partial. Anything else is an error.
                if (resp.code !in listOf(200, 206)) {
                    throw DownloadError.HttpError(resp.code)
                }

                // If we asked for a Range and the server replied 200, it's
                // sending the whole thing — restart hash + truncate file.
                var localWritten = written
                var localSha = sha
                if (written > 0 && resp.code == 200) {
                    localSha = MessageDigest.getInstance("SHA-256")
                    localWritten = 0
                    partial.delete()
                }

                val body = resp.body ?: throw DownloadError.HttpError(resp.code)
                val contentLength = body.contentLength()  // -1 if unknown
                val totalBytes: Long? = if (contentLength >= 0) localWritten + contentLength else null

                // Edge case: existing partial larger than remote total → corrupt.
                // Set restart flag, exit `use { }` so the connection is released,
                // then loop with no `.partial` → fresh download next iteration.
                if (totalBytes != null && localWritten > totalBytes) {
                    partial.delete()
                    restart = true
                    return@use
                }

                RandomAccessFile(partial, "rw").use { raf ->
                    raf.seek(localWritten)
                    val src = body.byteStream()
                    val buf = ByteArray(64 * 1024)
                    val debounceMs = 100L
                    // Initial 0% emit so callers see we've started.
                    onProgress(localWritten, totalBytes)
                    var lastEmit = System.currentTimeMillis()
                    while (true) {
                        val n = src.read(buf)
                        if (n <= 0) break
                        raf.write(buf, 0, n)
                        localSha.update(buf, 0, n)
                        localWritten += n
                        val now = System.currentTimeMillis()
                        if (now - lastEmit >= debounceMs) {
                            onProgress(localWritten, totalBytes)
                            lastEmit = now
                        }
                    }
                }
                // Final progress emit.
                onProgress(localWritten, totalBytes)

                // Step 5: verify.
                val gotHex = localSha.digest().joinToString("") { "%02x".format(it) }
                if (gotHex != expected) {
                    partial.delete()
                    final.delete()
                    throw DownloadError.ChecksumMismatch(expected, gotHex)
                }
            }

            if (restart) {
                attempt++
                continue
            }

            // Step 6: atomic rename.
            if (final.exists()) final.delete()
            if (!partial.renameTo(final)) {
                // Fallback: copy + delete (cross-device or other rename failure).
                partial.copyTo(final, overwrite = true)
                partial.delete()
            }
            return final.absolutePath to false
        }
        throw IllegalStateException("Could not complete download after oversized-partial restart")
    }

    // MARK: - Helpers

    private fun sha256OfFile(file: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { ins ->
            val buf = ByteArray(64 * 1024)
            while (true) {
                val n = ins.read(buf)
                if (n <= 0) break
                md.update(buf, 0, n)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }
}

/** Mirror of `CachedModelInfo` from `@dvai-bridge/capacitor` types. */
data class CachedModelInfo(
    val filename: String,
    val path: String,
    val bytes: Long,
    val sha256: String,
)
