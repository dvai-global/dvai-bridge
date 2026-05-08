package co.deepvoiceai.bridge

import co.deepvoiceai.bridge.shared.core.discovery.NsdDiscovery
import co.deepvoiceai.bridge.shared.core.discovery.Peer
import co.deepvoiceai.bridge.shared.core.offload.OffloadConfig
import co.deepvoiceai.bridge.shared.core.pairing.PairingPolicy
import io.ktor.client.HttpClient
import io.ktor.client.engine.cio.CIO as ClientCIO
import io.ktor.client.plugins.HttpTimeout
import io.ktor.client.request.headers
import io.ktor.client.request.prepareRequest
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsChannel
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.contentType
import io.ktor.server.application.call
import io.ktor.server.application.install
import io.ktor.server.cio.CIO as ServerCIO
import io.ktor.server.engine.ApplicationEngine
import io.ktor.server.engine.embeddedServer
import io.ktor.server.plugins.statuspages.StatusPages
import io.ktor.server.request.httpMethod
import io.ktor.server.request.receiveChannel
import io.ktor.server.request.uri
import io.ktor.server.response.respondBytes
import io.ktor.server.response.respondBytesWriter
import io.ktor.server.response.respondText
import io.ktor.server.routing.route
import io.ktor.server.routing.routing
import io.ktor.utils.io.ByteReadChannel
import io.ktor.utils.io.ByteWriteChannel
import io.ktor.utils.io.copyAndClose
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import java.net.BindException
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * v3.2 — Pre-routing HTTP proxy for the Android SDK.
 *
 * Architecture:
 *
 *     consumer app -> http://127.0.0.1:proxyPort/v1/...
 *                          |
 *                          +-- if local-decision -> forward to
 *                          |     http://127.0.0.1:backendPort/v1/...
 *                          |     (the native backend's internal port)
 *                          |
 *                          +-- if offload-decision -> HMAC-sign + forward to
 *                                http://peer-ip:peer-port/v1/...
 *                                (X-DVAI-Peer-Device-Id, X-DVAI-App-Id,
 *                                 X-DVAI-Nonce, X-DVAI-Signature)
 *
 * SSE-aware: when the consumer's request body has `stream: true` (or the
 * upstream replies with `Content-Type: text/event-stream`), bytes pipe
 * through unmodified so the consumer's OpenAI client gets incremental
 * tokens.
 *
 * Lifecycle is owned by [DVAIBridge]. Don't construct from consumer code.
 *
 * @param backendBaseUrl The native backend's internal loopback URL (e.g.
 *   `http://127.0.0.1:38884`). Null when the SDK is in offload-only mode
 *   (no backend; every request must forward to a peer or 503).
 * @param offloadConfig  The active OffloadConfig — read per-request so
 *   `enabled` / `minLocalCapability` flips at runtime are honored.
 * @param pairingPolicy  Source of pairing keys for HMAC-signing.
 * @param discovery      Source of the live peer list per request.
 * @param appId          This consumer app's identifier — surfaced as
 *   X-DVAI-App-Id on forwarded requests.
 * @param selfDeviceId   This device's stable identifier — surfaced as
 *   X-DVAI-Peer-Device-Id so peers verify the HMAC against the right key.
 */
class OffloadProxy(
    private val backendBaseUrl: String?,
    private val offloadConfig: OffloadConfig,
    private val pairingPolicy: PairingPolicy?,
    /** Snapshot of the live peer list. Defaults to [discovery]?.peers(). */
    private val peerProvider: () -> List<Peer>,
    private val appId: String,
    private val selfDeviceId: String,
) {

    /**
     * Convenience constructor used by [DVAIBridge] — wraps an
     * NsdDiscovery's peer list as the provider. Tests can use the
     * primary constructor to inject a fake peer source.
     */
    constructor(
        backendBaseUrl: String?,
        offloadConfig: OffloadConfig,
        pairingPolicy: PairingPolicy?,
        discovery: NsdDiscovery?,
        appId: String,
        selfDeviceId: String,
    ) : this(
        backendBaseUrl = backendBaseUrl,
        offloadConfig = offloadConfig,
        pairingPolicy = pairingPolicy,
        peerProvider = { discovery?.peers() ?: emptyList() },
        appId = appId,
        selfDeviceId = selfDeviceId,
    )

    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    private val client: HttpClient = HttpClient(ClientCIO) {
        install(HttpTimeout) {
            requestTimeoutMillis = REQUEST_TIMEOUT_MS
            connectTimeoutMillis = 10_000
            socketTimeoutMillis = REQUEST_TIMEOUT_MS
        }
        expectSuccess = false
    }

    @Volatile private var server: ApplicationEngine? = null
    @Volatile private var boundPort: Int = -1

    /**
     * Bind the proxy. Tries [basePort], [basePort]+1, ... up to
     * [maxAttempts] times. Returns the bound port.
     */
    fun start(basePort: Int = DEFAULT_BASE_PORT, maxAttempts: Int = 16): Int {
        require(server == null) { "OffloadProxy already started" }

        var lastError: Throwable? = null
        for (attempt in 0 until maxAttempts) {
            val port = basePort + attempt
            try {
                val engine = embeddedServer(ServerCIO, port = port, host = "127.0.0.1") {
                    install(StatusPages) {
                        exception<Throwable> { call, cause ->
                            call.respondText(
                                """{"error":{"type":"proxy_error","code":500,"message":"${escapeJson(cause.message ?: cause::class.qualifiedName ?: "internal error")}"}}""",
                                ContentType.Application.Json,
                                HttpStatusCode.InternalServerError,
                            )
                        }
                    }
                    routing {
                        // Catch-all — the route logic is inside the handler.
                        // `{...}` matches any path including slashes; the
                        // bare `handle { }` form without a path pattern
                        // doesn't actually wire a handler in Ktor 2.3.
                        route("{...}") {
                            handle {
                                handleRequest(call)
                            }
                        }
                    }
                }
                engine.start(wait = false)
                server = engine
                boundPort = port
                return port
            } catch (e: BindException) {
                lastError = e
            } catch (e: Throwable) {
                lastError = e
            }
        }
        throw DVAIBridgeError.BackendError(
            lastError ?: RuntimeException(
                "OffloadProxy: failed to bind any port in $basePort..${basePort + maxAttempts - 1}",
            ),
        )
    }

    /** Stop the proxy + close the HTTP client. Idempotent. */
    fun stop() {
        try {
            server?.stop(gracePeriodMillis = 500, timeoutMillis = 2_000)
        } catch (_: Throwable) {
        }
        server = null
        boundPort = -1
        try {
            client.close()
        } catch (_: Throwable) {
        }
    }

    /** Public bind URL once started; null before start(). */
    fun baseUrl(): String? = if (boundPort > 0) "http://127.0.0.1:$boundPort" else null

    /* ================================================================== *
     * Request handler                                                    *
     * ================================================================== */

    private suspend fun handleRequest(call: io.ktor.server.application.ApplicationCall) {
        val incomingUri = call.request.uri
        val method = call.request.httpMethod
        val incomingHeaders = call.request.headers.toLowerCaseMap()
        val bodyBytes: ByteArray = call.receiveChannel().toByteArray(MAX_REQUEST_BYTES)

        val decision = decideRoute(incomingUri, bodyBytes, incomingHeaders)
        when (decision) {
            is RouteDecision.Local ->
                forwardToLocal(call, method, incomingUri, bodyBytes, incomingHeaders)
            is RouteDecision.Offload ->
                forwardToPeer(call, decision, method, incomingUri, bodyBytes, incomingHeaders)
            is RouteDecision.NoCapableDevice -> {
                call.respondText(
                    decision.body,
                    ContentType.Application.Json,
                    HttpStatusCode.ServiceUnavailable,
                )
            }
        }
    }

    /* ================================================================== *
     * Decision logic                                                     *
     * ================================================================== */

    internal sealed class RouteDecision {
        data object Local : RouteDecision()
        data class Offload(val baseUrl: String, val peerDeviceId: String) : RouteDecision()
        data class NoCapableDevice(val body: String) : RouteDecision()
    }

    internal fun decideRoute(
        path: String,
        body: ByteArray,
        headers: Map<String, String>,
    ): RouteDecision {
        val isChatCompletion =
            path.endsWith("/chat/completions") || path.endsWith("/v1/chat/completions")

        if (!isChatCompletion) {
            return if (backendBaseUrl != null) RouteDecision.Local
                else RouteDecision.NoCapableDevice(noLocalBackendError())
        }

        if (!offloadConfig.enabled) {
            return if (backendBaseUrl != null) RouteDecision.Local
                else RouteDecision.NoCapableDevice(noLocalBackendError())
        }

        val offloadHeader = headers["x-dvai-offload"]?.lowercase() ?: "prefer"
        if (offloadHeader == "never") {
            return if (backendBaseUrl != null) RouteDecision.Local
                else RouteDecision.NoCapableDevice(noLocalBackendError())
        }

        val modelId = readModelId(body) ?: ""
        val peers = peerProvider()

        val best = pickBestPeer(peers, modelId)
        val threshold = offloadConfig.minLocalCapability

        if (offloadHeader == "require") {
            if (best != null) {
                return RouteDecision.Offload(best.peer.baseUrl, best.peer.deviceId)
            }
            return RouteDecision.NoCapableDevice(
                noCapableDeviceError(localCapability = 0.0, required = threshold),
            )
        }

        // header == "prefer" (default).
        if (best != null && best.score >= threshold) {
            return RouteDecision.Offload(best.peer.baseUrl, best.peer.deviceId)
        }
        if (backendBaseUrl != null) return RouteDecision.Local
        return RouteDecision.NoCapableDevice(
            noCapableDeviceError(localCapability = 0.0, required = threshold),
        )
    }

    internal data class RankedPeer(val peer: Peer, val score: Double, val hasModel: Boolean)

    internal fun pickBestPeer(peers: List<Peer>, modelId: String): RankedPeer? {
        val ranked = peers
            .map { p ->
                val score = p.capability[modelId] ?: 0.0
                RankedPeer(p, score, p.loadedModels.contains(modelId))
            }
            .filter { it.score > 0.0 }
            .sortedWith(
                compareByDescending<RankedPeer> { it.hasModel }
                    .thenByDescending { it.score },
            )
        return ranked.firstOrNull()
    }

    /* ================================================================== *
     * Forwarding                                                         *
     * ================================================================== */

    private suspend fun forwardToLocal(
        call: io.ktor.server.application.ApplicationCall,
        method: HttpMethod,
        path: String,
        body: ByteArray,
        headers: Map<String, String>,
    ) {
        val target = "${backendBaseUrl!!.trimEnd('/')}$path"
        forwardRequest(call, method, target, body, headers, signRequest = false, peerDeviceId = null)
    }

    private suspend fun forwardToPeer(
        call: io.ktor.server.application.ApplicationCall,
        decision: RouteDecision.Offload,
        method: HttpMethod,
        path: String,
        body: ByteArray,
        headers: Map<String, String>,
    ) {
        val targetBase = decision.baseUrl.trimEnd('/')
        // Peer might or might not have /v1 in its baseUrl; normalize.
        val normalizedPath = if (path.startsWith("/v1")) path else "/v1${path.removePrefix("/")}"
        val target = "$targetBase$normalizedPath"
        forwardRequest(call, method, target, body, headers, signRequest = true, peerDeviceId = decision.peerDeviceId)
    }

    private suspend fun forwardRequest(
        call: io.ktor.server.application.ApplicationCall,
        method: HttpMethod,
        target: String,
        body: ByteArray,
        headers: Map<String, String>,
        signRequest: Boolean,
        peerDeviceId: String?,
    ) {
        val streamRequested = isStreamRequested(body, headers)

        client.prepareRequest(target) {
            this.method = method
            headers {
                for ((k, v) in headers) {
                    if (k in HOP_BY_HOP) continue
                    if (k == "host" || k == "content-length") continue
                    append(k, v)
                }
                if (signRequest && peerDeviceId != null && pairingPolicy != null) {
                    val pairing = pairingPolicy.getActive(peerDeviceId)
                    if (pairing != null) {
                        val nonce = newNonce()
                        val signature = signCanonical(
                            method = method.value,
                            path = pathOnly(target),
                            body = body,
                            nonce = nonce,
                            pairingKey = pairing.pairingKey,
                        )
                        append("X-DVAI-Peer-Device-Id", selfDeviceId)
                        append("X-DVAI-App-Id", appId)
                        append("X-DVAI-Nonce", nonce)
                        append("X-DVAI-Signature", signature)
                        append("X-DVAI-Forwarded", "1")
                    }
                }
            }
            if (body.isNotEmpty()) {
                contentType(ContentType.Application.Json)
                setBody(body)
            }
        }.execute { response: HttpResponse ->
            relayResponse(call, response, streamRequested)
        }
    }

    private suspend fun relayResponse(
        call: io.ktor.server.application.ApplicationCall,
        response: HttpResponse,
        streamRequested: Boolean,
    ) {
        // Echo upstream headers (skipping hop-by-hop + content-length;
        // Ktor recomputes the latter).
        for ((name, values) in response.headers.entries()) {
            val lname = name.lowercase()
            if (lname in HOP_BY_HOP) continue
            if (lname == HttpHeaders.ContentLength.lowercase()) continue
            for (v in values) {
                call.response.headers.append(name, v, safeOnly = false)
            }
        }
        val upstreamCT = response.headers[HttpHeaders.ContentType]
        val isSse = streamRequested ||
            (upstreamCT?.startsWith("text/event-stream", ignoreCase = true) == true)

        val statusCode = HttpStatusCode.fromValue(response.status.value)

        if (isSse) {
            call.respondBytesWriter(
                contentType = ContentType.parse(upstreamCT ?: "text/event-stream"),
                status = statusCode,
            ) {
                response.bodyAsChannel().copyAndClose(this)
            }
        } else {
            val bytes = response.bodyAsChannel().toByteArray(MAX_RESPONSE_BYTES)
            call.respondBytes(
                bytes,
                ContentType.parse(upstreamCT ?: "application/json"),
                statusCode,
            )
        }
    }

    /* ================================================================== *
     * HMAC                                                               *
     * ================================================================== */

    private fun signCanonical(
        method: String,
        path: String,
        body: ByteArray,
        nonce: String,
        pairingKey: String,
    ): String {
        val mac = Mac.getInstance("HmacSHA256").apply {
            init(SecretKeySpec(pairingKey.toByteArray(Charsets.UTF_8), "HmacSHA256"))
        }
        mac.update(method.uppercase().toByteArray(Charsets.UTF_8))
        mac.update(LF)
        mac.update(path.toByteArray(Charsets.UTF_8))
        mac.update(LF)
        mac.update(nonce.toByteArray(Charsets.UTF_8))
        mac.update(LF)
        mac.update(body)
        return mac.doFinal().toHex()
    }

    private fun newNonce(): String {
        val bytes = ByteArray(16)
        SecureRandom().nextBytes(bytes)
        return bytes.toHex()
    }

    /* ================================================================== *
     * Helpers                                                            *
     * ================================================================== */

    private fun readModelId(body: ByteArray): String? {
        if (body.isEmpty()) return null
        return try {
            val parsed = json.parseToJsonElement(body.decodeToString())
            (parsed as? JsonObject)?.get("model")?.jsonPrimitive?.contentOrNull
        } catch (_: Throwable) {
            null
        }
    }

    private fun isStreamRequested(body: ByteArray, headers: Map<String, String>): Boolean {
        if (headers["accept"]?.contains("text/event-stream", ignoreCase = true) == true) return true
        if (body.isEmpty()) return false
        return try {
            val parsed = json.parseToJsonElement(body.decodeToString())
            (parsed as? JsonObject)?.get("stream")?.jsonPrimitive?.boolean == true
        } catch (_: Throwable) {
            false
        }
    }

    private fun pathOnly(url: String): String =
        try {
            java.net.URI(url).rawPath.takeIf { !it.isNullOrEmpty() } ?: "/"
        } catch (_: Throwable) {
            "/"
        }

    private fun noLocalBackendError(): String =
        """{"error":{"type":"no_local_backend","code":503,"message":"DVAI is in offload-only mode and no peer is available."}}"""

    private fun noCapableDeviceError(localCapability: Double, required: Double): String =
        """{"error":{"type":"no_capable_device","code":503,"message":"No device with capability >= $required tok/s available.","localCapability":$localCapability,"requiredAtLeast":$required}}"""

    companion object {
        const val DEFAULT_BASE_PORT: Int = 38883
        private const val REQUEST_TIMEOUT_MS: Long = 600_000L         // 10 min
        private const val MAX_REQUEST_BYTES: Long = 32L * 1024 * 1024  // 32 MB
        private const val MAX_RESPONSE_BYTES: Long = 64L * 1024 * 1024 // 64 MB
        private val LF = byteArrayOf(0x0A)
        private val HOP_BY_HOP = setOf(
            "connection", "keep-alive", "proxy-authenticate",
            "proxy-authorization", "te", "trailers",
            "transfer-encoding", "upgrade", "host",
        )
    }
}

/* -------------------------------------------------------------------------- */
/* File-private helpers                                                       */
/* -------------------------------------------------------------------------- */

private fun io.ktor.http.Headers.toLowerCaseMap(): Map<String, String> {
    val out = HashMap<String, String>()
    for (name in names()) {
        out[name.lowercase()] = get(name).orEmpty()
    }
    return out
}

private suspend fun ByteReadChannel.toByteArray(maxBytes: Long): ByteArray {
    val baos = java.io.ByteArrayOutputStream()
    val buf = ByteArray(8192)
    var total: Long = 0
    while (true) {
        val n = readAvailable(buf, 0, buf.size)
        if (n <= 0) break
        total += n
        if (total > maxBytes) {
            throw IllegalStateException("body exceeds $maxBytes bytes")
        }
        baos.write(buf, 0, n)
    }
    return baos.toByteArray()
}

private fun ByteArray.toHex(): String {
    val sb = StringBuilder(size * 2)
    for (b in this) {
        sb.append("%02x".format(b))
    }
    return sb.toString()
}

private fun escapeJson(s: String): String =
    s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r")
