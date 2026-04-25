package co.deepvoiceai.dvaibridge.llama

import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

class HttpServerTest {
    private val servers = mutableListOf<HttpServer>()

    @After
    fun tearDown() = runBlocking {
        servers.forEach { runCatching { it.stop() } }
        servers.clear()
    }

    @Test
    fun `bind base port when free`() = runBlocking {
        val server = HttpServer().also { servers.add(it) }
        val port = server.tryBind(basePort = 39101, maxAttempts = 4, host = "127.0.0.1")
        assertEquals(39101, port)
    }

    @Test
    fun `falls back to next port on conflict`() = runBlocking {
        val blocker = HttpServer().also { servers.add(it) }
        blocker.tryBind(basePort = 39110, maxAttempts = 1, host = "127.0.0.1")

        val server = HttpServer().also { servers.add(it) }
        val port = server.tryBind(basePort = 39110, maxAttempts = 4, host = "127.0.0.1")
        assertEquals(39111, port)
    }

    @Test
    fun `stop is idempotent`() = runBlocking {
        val server = HttpServer().also { servers.add(it) }
        // Stop before start — should not throw
        server.stop()
        server.tryBind(basePort = 39120, maxAttempts = 1, host = "127.0.0.1")
        server.stop()
        // Double-stop — should not throw
        server.stop()
    }

    @Test
    fun `throws actionable error when all ports blocked`() = runBlocking {
        @Suppress("UNUSED_VARIABLE")
        val blockers = (0 until 3).map { i ->
            HttpServer().also {
                servers.add(it)
                it.tryBind(basePort = 39130 + i, maxAttempts = 1, host = "127.0.0.1")
            }
        }
        val server = HttpServer().also { servers.add(it) }
        try {
            server.tryBind(basePort = 39130, maxAttempts = 3, host = "127.0.0.1")
            fail("Expected exception")
        } catch (e: IllegalStateException) {
            assertTrue(
                "Error should name the tried range: ${e.message}",
                e.message?.contains("39130..39132") == true,
            )
        }
    }
}
