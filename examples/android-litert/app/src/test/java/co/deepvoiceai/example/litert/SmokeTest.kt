package co.deepvoiceai.example.litert

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
 * JVM-only smoke test for the LiteRT example. Mirrors the structure of
 * the android-llama / android-mediapipe smokes; the on-device run lives
 * in `connectedAndroidTest`.
 */
class SmokeTest {

    @Test
    fun `BackendKind LiteRT is reachable from the example classpath`() {
        assertEquals(BackendKind.LiteRT, BackendKind.valueOf("LiteRT"))
    }

    @Test
    fun `BackendSelector resolves a tflite path to LiteRT`() {
        val opts = StartOptions(
            backend = BackendKind.Auto,
            modelPath = "/sdcard/Download/Llama-3.2-1B-Instruct.tflite",
        )
        assertEquals(BackendKind.LiteRT, BackendSelector.resolve(opts))
    }

    @Test
    fun `BackendSelector resolves a litertlm path to LiteRT`() {
        val opts = StartOptions(
            backend = BackendKind.Auto,
            modelPath = "/sdcard/Download/something.litertlm",
        )
        assertEquals(BackendKind.LiteRT, BackendSelector.resolve(opts))
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
        val host = OpenAIHost(baseUrl = "http://127.0.0.1:38883/v1/")
        assertEquals("http://127.0.0.1:38883/v1/", host.baseUrl)

        val request = ChatCompletionRequest(
            model = ModelId("Llama-3.2-1B-Instruct"),
            messages = listOf(
                ChatMessage(role = ChatRole.User, content = "Hello!"),
            ),
        )
        assertNotNull(request)
    }
}
