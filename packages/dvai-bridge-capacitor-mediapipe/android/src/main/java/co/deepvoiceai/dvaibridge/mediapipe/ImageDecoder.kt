package co.deepvoiceai.dvaibridge.mediapipe

import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.net.URI
import java.net.URLDecoder
import java.util.Base64
import java.util.concurrent.TimeUnit

/**
 * Errors thrown by [ImageDecoder.resolve] when the input URL string can't
 * be turned into image bytes.
 */
sealed class ImageSourceError(msg: String) : Exception(msg) {
    class MalformedDataURL(url: String) : ImageSourceError("malformed data URL: $url")
    class MalformedURL(url: String) : ImageSourceError("malformed URL: $url")
    class InvalidScheme(scheme: String) : ImageSourceError("unsupported URL scheme: $scheme")
    class HttpError(val status: Int) : ImageSourceError("HTTP $status")
    class Base64DecodeFailed : ImageSourceError("base64 decode failed")
}

/**
 * Resolves any of the three image URL schemes accepted by the DVAI bridge
 * (`data:`, `https:`/`http:`, `file:`) into the raw encoded image bytes
 * (PNG/JPEG/etc.). Format decoding into pixel buffers is performed downstream
 * by Android's `BitmapFactory` (then wrapped in `MPImage` via
 * `BitmapImageBuilder`) — this layer just materializes the encoded bytes.
 *
 * Byte-identical to capacitor-llama's `ImageDecoder` modulo package
 * declaration. If you fix a bug here, mirror it there (and vice versa).
 *
 * Blocking: HTTP fetches use OkHttp synchronously. Call from a background
 * thread or coroutine on `Dispatchers.IO` (the plugin layer already does).
 */
object ImageDecoder {
    private val httpClient: OkHttpClient by lazy {
        // `callTimeout` caps the entire HTTP exchange (DNS + connect + write
        // + read + redirect) at 30s so worst-case latency matches iOS, where
        // `URLRequest.timeoutInterval = 30` covers the whole request.
        OkHttpClient.Builder()
            .callTimeout(30, TimeUnit.SECONDS)
            .build()
    }

    /**
     * Resolve any supported URL scheme into raw image bytes.
     *
     * - `data:` URLs are parsed for an optional `;base64` token and decoded
     *   accordingly (URL-encoded payloads are also supported).
     * - `https:` / `http:` URLs are fetched via OkHttp with a 30s timeout;
     *   non-2xx responses throw [ImageSourceError.HttpError].
     * - `file:` URLs are read off disk via [File.readBytes].
     * - Any other scheme throws [ImageSourceError.InvalidScheme].
     * - URLs that fail to parse, lack a scheme, or have a missing/empty
     *   `file:` path throw [ImageSourceError.MalformedURL].
     */
    fun resolve(url: String): ByteArray {
        if (url.startsWith("data:")) {
            return resolveDataURL(url)
        }
        return resolveWithClient(url, httpClient)
    }

    /**
     * Test seam: same contract as [resolve] but lets the caller inject an
     * [OkHttpClient] (e.g. one pointed at MockWebServer). Data URLs still
     * short-circuit before the client is consulted.
     */
    internal fun resolveWithClient(url: String, client: OkHttpClient): ByteArray {
        if (url.startsWith("data:")) {
            return resolveDataURL(url)
        }
        val parsed = try {
            URI(url)
        } catch (_: Exception) {
            throw ImageSourceError.MalformedURL(url)
        }
        val scheme = parsed.scheme?.lowercase() ?: throw ImageSourceError.MalformedURL(url)
        return when (scheme) {
            "https", "http" -> fetchHttp(url, client)
            "file" -> {
                val path = parsed.path
                if (path.isNullOrEmpty()) throw ImageSourceError.MalformedURL(url)
                File(path).readBytes()
            }
            else -> throw ImageSourceError.InvalidScheme(scheme)
        }
    }

    /** Parse a `data:[<mediatype>][;base64],<payload>` URL into raw bytes. */
    private fun resolveDataURL(url: String): ByteArray {
        val commaIdx = url.indexOf(',')
        if (commaIdx < 0) throw ImageSourceError.MalformedDataURL(url)
        // Skip the leading "data:" (5 chars) and isolate header / body.
        val header = url.substring(5, commaIdx)
        val body = url.substring(commaIdx + 1)
        if (header.contains(";base64")) {
            return try {
                Base64.getDecoder().decode(body)
            } catch (_: IllegalArgumentException) {
                throw ImageSourceError.Base64DecodeFailed()
            }
        }
        // Non-base64: payload is percent-encoded text per RFC 2397.
        return URLDecoder.decode(body, Charsets.UTF_8.name()).toByteArray(Charsets.UTF_8)
    }

    private fun fetchHttp(url: String, client: OkHttpClient): ByteArray {
        client.newCall(Request.Builder().url(url).build()).execute().use { resp ->
            if (!resp.isSuccessful) throw ImageSourceError.HttpError(resp.code)
            return resp.body?.bytes() ?: ByteArray(0)
        }
    }
}
