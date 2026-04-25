package co.deepvoiceai.dvaibridge.mediapipe

import org.junit.Assert.assertNotNull
import org.junit.Test

class SmokeTest {
    @Test
    fun pluginClassExists() {
        assertNotNull(DVAIBridgeMediaPipePlugin::class.java)
    }

    @Test
    fun handlerContextDataClassExists() {
        // HandlerContext is copied verbatim from capacitor-llama; this
        // confirms the dispatch-infra files compile in the new package.
        val ctx = HandlerContext(modelId = "test", backendName = "mediapipe")
        assertNotNull(ctx)
    }
}
