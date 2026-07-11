package co.deepvoiceai.bridge.litertlm

import co.deepvoiceai.bridge.shared.core.HandlerContext
import org.junit.Assert.assertNotNull
import org.junit.Test

class SmokeTest {
    @Test
    fun pluginClassExists() {
        assertNotNull(DVAIBridgeLiteRTLMPlugin::class.java)
    }

    @Test
    fun handlerContextDataClassExists() {
        // HandlerContext now lives in shared-core (Phase 3D Task 2); this
        // confirms the wrapper still resolves it transitively through the
        // litert-core project dependency.
        val ctx = HandlerContext(modelId = "test", backendName = "litertlm")
        assertNotNull(ctx)
    }
}
