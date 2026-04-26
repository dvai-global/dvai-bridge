package co.deepvoiceai.bridge.llama.core

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayOutputStream

/**
 * Instrumented tests run on a real device or emulator (MediaCodec is not
 * available in JVM unit tests). Fixtures are bundled into the test APK from
 * `src/androidTest/assets/audio/`.
 */
@RunWith(AndroidJUnit4::class)
class AudioDecoderInstrumentedTest {
    private fun loadFixture(name: String): ByteArray {
        val out = ByteArrayOutputStream()
        InstrumentationRegistry.getInstrumentation().context.assets
            .open("audio/$name").use { it.copyTo(out) }
        return out.toByteArray()
    }

    @Test
    fun pcm16PassesThrough() {
        val pcm = loadFixture("pcm16-1s-16khz-mono.bin")
        val result = AudioDecoder.decode(pcm, AudioFormat.PCM16)
        assertEquals(pcm.size, result.size)
    }

    @Test
    fun wavDecodesToPcm16Mono16khz() {
        val wav = loadFixture("wav-1s-16khz-mono.wav")
        val result = AudioDecoder.decode(wav, AudioFormat.WAV)
        // 1s @ 16kHz mono PCM16 = 32000 bytes (allow ±5%).
        assertTrue("Got ${result.size} bytes", result.size in 30000..34000)
    }

    @Test
    fun m4aDecodesToPcm16Mono16khz() {
        val m4a = loadFixture("m4a-1s.m4a")
        val result = AudioDecoder.decode(m4a, AudioFormat.M4A)
        // M4A AAC 1s ≈ 32000 bytes; AAC priming may shave a few hundred samples.
        assertTrue("Got ${result.size} bytes", result.size in 25000..36000)
    }
}
