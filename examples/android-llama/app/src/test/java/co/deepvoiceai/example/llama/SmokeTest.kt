package co.deepvoiceai.example.llama

import co.deepvoiceai.bridge.BackendKind
import co.deepvoiceai.bridge.BackendSelector
import co.deepvoiceai.bridge.DVAIBridge
import co.deepvoiceai.bridge.StartOptions
import com.aallam.openai.api.chat.ChatCompletionRequest
import com.aallam.openai.api.chat.ChatMessage
import com.aallam.openai.api.chat.ChatRole
import com.aallam.openai.api.model.ModelId
import com.aallam.openai.client.OpenAIHost
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Test

/**
 * JVM-only smoke test for the Llama example. Verifies the example's
 * dependencies resolve and the SDK's public types are reachable on the
 * test classpath, without booting the JNI llama.cpp engine (that needs
 * a real Android device + the GGUF model file pushed to
 * `/sdcard/Download/`, covered by `connectedAndroidTest` per
 * `smoke.sh`).
 */
class SmokeTest {

    @Test
    fun `BackendKind Llama is reachable from the example classpath`() {
        // Compile-time check: the import resolves. Runtime check: enum
        // resolution gives back the same singleton.
        assertEquals(BackendKind.Llama, BackendKind.valueOf("Llama"))
    }

    @Test
    fun `BackendSelector resolves an explicit Llama backend without invoking native code`() {
        val opts = StartOptions(
            backend = BackendKind.Llama,
            modelPath = "/sdcard/Download/Llama-3.2-1B-Instruct-Q4_K_M.gguf",
        )
        assertEquals(BackendKind.Llama, BackendSelector.resolve(opts))
    }

    @Test
    fun `DVAIBridge status reads as not-running before start`() {
        val status = DVAIBridge.status()
        assertFalse("expected DVAIBridge.status().running to be false at boot", status.running)
        assertEquals(null, status.baseUrl)
        assertEquals(null, status.backend)
    }

    @Test
    fun `OpenAI types are reachable on the example classpath`() {
        // We deliberately do NOT construct the OpenAI client here —
        // its Ktor engine plugins assume a configured HTTP transport
        // and aren't relevant to a JVM-only unit smoke. The
        // compile-time check that all four imports resolve is the real
        // value-add (catches broken dep wiring before the apk lands on
        // a device).
        val host = OpenAIHost(baseUrl = "http://127.0.0.1:38883/v1/")
        assertEquals("http://127.0.0.1:38883/v1/", host.baseUrl)

        val request = ChatCompletionRequest(
            model = ModelId("Llama-3.2-1B-Instruct-Q4_K_M"),
            messages = listOf(
                ChatMessage(role = ChatRole.User, content = "Hello!"),
            ),
        )
        assertNotNull(request)
    }
}
