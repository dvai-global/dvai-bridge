package co.deepvoiceai.dvaibridge.llama

import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File
import java.nio.file.Files

@RunWith(RobolectricTestRunner::class)
class ImageDecoderTest {
    private lateinit var server: MockWebServer

    @Before
    fun setUp() {
        server = MockWebServer().apply { start(0) }
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    /** `data:image/png;base64,...` decodes to bytes starting with the PNG magic header. */
    @Test
    fun `data URL base64 decodes to bytes`() {
        val url = loadResourceText("tiny-test-base64.txt")
        val bytes = ImageDecoder.resolve(url)
        assertArrayEquals(
            byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A),
            bytes.copyOfRange(0, 8),
        )
    }

    /** `https://...` URLs fetch the body bytes verbatim. */
    @Test
    fun `https URL fetches bytes`() {
        val payload = loadResource("tiny-test.png")
        server.enqueue(MockResponse().setBody(Buffer().apply { write(payload) }))
        val bytes = ImageDecoder.resolveWithClient(
            server.url("/img.png").toString(),
            OkHttpClient(),
        )
        assertArrayEquals(payload, bytes)
    }

    /** `file://` URLs read the file off disk. */
    @Test
    fun `file URL reads bytes`() {
        val payload = loadResource("tiny-test.png")
        val tmp = Files.createTempFile("dvai-image-", ".png").toFile().apply {
            writeBytes(payload)
            deleteOnExit()
        }
        try {
            val bytes = ImageDecoder.resolve(tmp.toURI().toString())
            assertArrayEquals(payload, bytes)
        } finally {
            tmp.delete()
        }
    }

    /** Unsupported scheme → `InvalidScheme`. */
    @Test(expected = ImageSourceError.InvalidScheme::class)
    fun `unsupported scheme throws`() {
        ImageDecoder.resolve("ftp://example.com/x.png")
    }

    /** `data:` URL with no comma → `MalformedDataURL`. */
    @Test(expected = ImageSourceError.MalformedDataURL::class)
    fun `malformed data URL throws`() {
        ImageDecoder.resolve("data:image/png;base64")
    }

    /** `file:` URL with no path → `MalformedURL` (was previously misreported as `InvalidScheme`). */
    @Test(expected = ImageSourceError.MalformedURL::class)
    fun `file URL with no path throws MalformedURL`() {
        ImageDecoder.resolve("file:")
    }

    /** HTTP non-2xx → `HttpError` carrying the status code. */
    @Test
    fun `http error throws HttpError`() {
        server.enqueue(MockResponse().setResponseCode(404))
        try {
            ImageDecoder.resolveWithClient(
                server.url("/missing.png").toString(),
                OkHttpClient(),
            )
            fail("Expected ImageSourceError.HttpError")
        } catch (e: ImageSourceError.HttpError) {
            assertEquals(404, e.status)
        }
    }

    private fun loadResource(name: String): ByteArray =
        javaClass.getResourceAsStream("/images/$name")
            ?.use { it.readBytes() }
            ?: error("missing test resource: /images/$name")

    private fun loadResourceText(name: String): String =
        javaClass.getResourceAsStream("/images/$name")
            ?.bufferedReader()
            ?.use { it.readText().trim() }
            ?: error("missing test resource: /images/$name")
}
