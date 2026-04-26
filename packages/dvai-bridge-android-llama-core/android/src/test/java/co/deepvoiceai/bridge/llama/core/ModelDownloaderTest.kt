package co.deepvoiceai.bridge.llama.core

import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File
import java.security.MessageDigest

@RunWith(RobolectricTestRunner::class)
class ModelDownloaderTest {
    private lateinit var tmpCacheDir: File
    private lateinit var downloader: ModelDownloader

    @Before
    fun setUp() {
        tmpCacheDir = File.createTempFile("dvai-modeldownloader-", "-test").apply {
            delete()
            mkdirs()
        }
        // context = null → only the override is consulted.
        downloader = ModelDownloader(context = null, cacheDirOverride = tmpCacheDir)
    }

    @After
    fun tearDown() {
        tmpCacheDir.deleteRecursively()
    }

    /** `cacheDir()` must create the directory if missing and return it. */
    @Test
    fun `cacheDir creates directory`() {
        // Delete and re-create on demand.
        tmpCacheDir.deleteRecursively()
        assertTrue(!tmpCacheDir.exists())
        val dir = downloader.cacheDir()
        assertEquals(tmpCacheDir.absolutePath, dir.absolutePath)
        assertTrue(dir.exists())
        assertTrue(dir.isDirectory)
    }

    /**
     * Cache hit: drop a known file with a known sha256 in the cache dir,
     * call `downloadModel(...)` with that sha + a deliberately broken URL.
     * Must return `cached: true` without ever attempting the network.
     */
    @Test
    fun `cache hit returns cached without network`() {
        val payload = "hello, dvai cache!".toByteArray(Charsets.UTF_8)
        val filename = "fixture.bin"
        File(tmpCacheDir, filename).writeBytes(payload)

        val md = MessageDigest.getInstance("SHA-256").apply { update(payload) }
        val hex = md.digest().joinToString("") { "%02x".format(it) }

        val (path, cached) = downloader.downloadModel(
            url = "https://invalid.dvai.test/should-not-fetch.bin",
            expectedSha256 = hex,
            destFilename = filename,
            headers = emptyMap(),
            onProgress = { _, _ -> },
        )
        assertTrue("expected cache-hit short-circuit", cached)
        assertEquals(File(tmpCacheDir, filename).absolutePath, path)
    }

    /**
     * `listCached()` enumerates regular files (skipping `.partial` and
     * dotfiles) and `deleteCached(...)` removes them.
     */
    @Test
    fun `list and delete`() {
        File(tmpCacheDir, "a.gguf").writeBytes("alpha".toByteArray())
        File(tmpCacheDir, "b.gguf").writeBytes("bravo".toByteArray())
        File(tmpCacheDir, "c.gguf.partial").writeBytes(byteArrayOf())
        File(tmpCacheDir, ".hidden").writeBytes(byteArrayOf())

        val listed = downloader.listCached()
        val names = listed.map { it.filename }.toSet()
        assertEquals(setOf("a.gguf", "b.gguf"), names)
        assertEquals(2, listed.size)
        for (info in listed) {
            assertTrue(info.bytes > 0)
            assertEquals(64, info.sha256.length)
            assertNotNull(info.path)
        }

        downloader.deleteCached("a.gguf")
        val listed2 = downloader.listCached()
        assertEquals(setOf("b.gguf"), listed2.map { it.filename }.toSet())
    }

    /**
     * Happy-path download: MockWebServer serves a payload, downloader writes
     * it to disk, sha256 verifies, returns `cached=false` and the on-disk
     * bytes match the served payload.
     */
    @Test
    fun `downloadModel writes file and verifies sha256`() {
        val payload = "hello dvai bridge".toByteArray()
        val expected = sha256Hex(payload)
        val server = MockWebServer().apply {
            enqueue(MockResponse().setBody(Buffer().apply { write(payload) }))
            start(0)
        }
        try {
            val (path, cached) = downloader.downloadModel(
                url = server.url("/test.bin").toString(),
                expectedSha256 = expected,
                destFilename = "test.bin",
                headers = emptyMap(),
                onProgress = { _, _ -> },
            )
            assertFalse("expected fresh download, not cache hit", cached)
            assertEquals(payload.toList(), File(path).readBytes().toList())
        } finally {
            server.shutdown()
        }
    }

    /**
     * Hash mismatch must throw AND clean up both the final file and the
     * `.partial` so a retry starts fresh — no orphan bytes left on disk.
     */
    @Test
    fun `downloadModel throws on hash mismatch and cleans up`() {
        val payload = "this won't match".toByteArray()
        val server = MockWebServer().apply {
            enqueue(MockResponse().setBody(Buffer().apply { write(payload) }))
            start(0)
        }
        try {
            try {
                downloader.downloadModel(
                    url = server.url("/bad.bin").toString(),
                    expectedSha256 = "0".repeat(64),  // wrong on purpose
                    destFilename = "bad.bin",
                    headers = emptyMap(),
                    onProgress = { _, _ -> },
                )
                fail("Expected ChecksumMismatch exception")
            } catch (e: ModelDownloader.DownloadError.ChecksumMismatch) {
                // expected
            }
            assertFalse(
                "final file must not exist after hash mismatch",
                File(tmpCacheDir, "bad.bin").exists(),
            )
            assertFalse(
                ".partial must not exist after hash mismatch",
                File(tmpCacheDir, "bad.bin.partial").exists(),
            )
        } finally {
            server.shutdown()
        }
    }

    private fun sha256Hex(bytes: ByteArray): String {
        val md = MessageDigest.getInstance("SHA-256")
        return md.digest(bytes).joinToString("") { "%02x".format(it) }
    }
}
