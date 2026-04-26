package co.deepvoiceai.bridge.llama

import org.junit.Assert.assertNotNull
import org.junit.Test

class SmokeTest {
    @Test
    fun pluginClassExists() {
        assertNotNull(DVAIBridgeLlamaPlugin::class.java)
    }
}
