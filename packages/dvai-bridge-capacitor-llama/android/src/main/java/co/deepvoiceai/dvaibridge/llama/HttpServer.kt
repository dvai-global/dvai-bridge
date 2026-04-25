package co.deepvoiceai.dvaibridge.llama

import io.ktor.server.cio.CIO
import io.ktor.server.engine.ApplicationEngine
import io.ktor.server.engine.embeddedServer
import kotlinx.coroutines.delay

/**
 * Wraps Ktor's CIO embedded server with port-fallback bind logic.
 *
 * Ktor 2.3.7's `embeddedServer(CIO, ...) { ... }` returns a
 * `BaseApplicationEngine` which is a subtype of [ApplicationEngine].
 * We hold the engine through that interface — `start(wait)` and
 * `stop(...)` are defined on it.
 */
class HttpServer {
    @Volatile private var engine: ApplicationEngine? = null
    @Volatile var boundPort: Int? = null
        private set

    /**
     * Try to bind to `basePort`, falling back to `basePort+1`, ..., up to
     * `maxAttempts` ports. Returns the port that bound successfully.
     * Throws [IllegalStateException] if all ports in the range are unavailable.
     */
    suspend fun tryBind(basePort: Int, maxAttempts: Int, host: String): Int {
        val lastPort = basePort + maxAttempts - 1
        for (i in 0 until maxAttempts) {
            val port = basePort + i
            val candidate: ApplicationEngine = embeddedServer(CIO, port = port, host = host) {
                // routes installed later via configure() in Task 29
            }
            try {
                candidate.start(wait = false)
                // CIO's start(wait = false) returns before the listening
                // socket is fully established. Probe the port to confirm
                // we actually grabbed it (vs. getting a silent failure).
                delay(100)
                if (!isListening(host, port)) {
                    runCatching { candidate.stop(0L, 100L) }
                    continue
                }
                this.engine = candidate
                this.boundPort = port
                return port
            } catch (_: Exception) {
                // BindException, IOException, or wrapped variant — try next port.
                runCatching { candidate.stop(0L, 100L) }
                continue
            }
        }
        throw IllegalStateException(
            "[DVAI] Could not bind HTTP transport to any port in range " +
                "$basePort..$lastPort (all in use). " +
                "Another local AI server may already be running.",
        )
    }

    /** Stops the server. Idempotent — safe to call multiple times. */
    suspend fun stop() {
        val s = engine ?: return
        engine = null
        boundPort = null
        try {
            s.stop(gracePeriodMillis = 100, timeoutMillis = 1000)
        } catch (_: Exception) {
            // best-effort
        }
    }

    fun isRunning(): Boolean = engine != null

    private fun isListening(host: String, port: Int): Boolean {
        return try {
            java.net.Socket().use { sock ->
                sock.connect(java.net.InetSocketAddress(host, port), 200)
                true
            }
        } catch (_: Exception) {
            false
        }
    }
}
