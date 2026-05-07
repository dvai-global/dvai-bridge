package co.deepvoiceai.example.mediapipe

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
 * JVM-only smoke test for the MediaPipe example. Mirrors the structure
 * of the android-llama smoke; the on-device end-to-end is gated to
 * `connectedAndroidTest` because LiteRT-LM's native libs only run on a
 * real device.
 */
class SmokeTest {

    @Test
    fun `BackendKind MediaPipe is reachable from the example classpath`() {
        assertEquals(BackendKind.MediaPipe, BackendKind.valueOf("MediaPipe"))
    }

    @Test
    fun `BackendSelector resolves an explicit MediaPipe backend without invoking native code`() {
        val opts = StartOptions(
            backend = BackendKind.MediaPipe,
            modelPath = "/sdcard/Download/gemma2-2b-it-cpu-int8.task",
        )
        assertEquals(BackendKind.MediaPipe, BackendSelector.resolve(opts))
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
            model = ModelId("gemma2-2b-it"),
            messages = listOf(
                ChatMessage(role = ChatRole.User, content = "Hello!"),
            ),
        )
        assertNotNull(request)
    }
}
