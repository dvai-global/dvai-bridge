package co.deepvoiceai.bridge.mediapipe

import co.deepvoiceai.bridge.shared.core.HandlerContext
import org.junit.Assert.assertNotNull
import org.junit.Test

class SmokeTest {
    @Test
    fun pluginClassExists() {
        assertNotNull(DVAIBridgeMediaPipePlugin::class.java)
    }

    @Test
    fun handlerContextDataClassExists() {
        // HandlerContext now lives in shared-core (Phase 3D Task 2); this
        // confirms the wrapper still resolves it transitively through the
        // mediapipe-core project dependency.
        val ctx = HandlerContext(modelId = "test", backendName = "mediapipe")
        assertNotNull(ctx)
    }
}
