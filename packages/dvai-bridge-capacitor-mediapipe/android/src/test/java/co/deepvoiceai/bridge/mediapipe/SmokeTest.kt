package co.deepvoiceai.bridge.mediapipe

import co.deepvoiceai.bridge.mediapipe.core.HandlerContext
import org.junit.Assert.assertNotNull
import org.junit.Test

class SmokeTest {
    @Test
    fun pluginClassExists() {
        assertNotNull(DVAIBridgeMediaPipePlugin::class.java)
    }

    @Test
    fun handlerContextDataClassExists() {
        // HandlerContext lives in the core package; this confirms the
        // project-dep wiring resolves correctly at compile time.
        val ctx = HandlerContext(modelId = "test", backendName = "mediapipe")
        assertNotNull(ctx)
    }
}
