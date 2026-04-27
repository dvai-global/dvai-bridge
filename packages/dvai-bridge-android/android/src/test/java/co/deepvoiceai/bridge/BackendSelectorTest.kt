package co.deepvoiceai.bridge

import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File
import java.nio.file.Files

class BackendSelectorTest {
    @Test
    fun `explicit backend bypasses resolution`() {
        for (kind in listOf(BackendKind.Llama, BackendKind.MediaPipe, BackendKind.LiteRT)) {
            val opts = StartOptions(backend = kind, modelPath = "/tmp/x.gguf")
            assertEquals(kind, BackendSelector.resolve(opts))
        }
    }

    @Test
    fun `auto with task suffix and existing file resolves to MediaPipe`() {
        val tmp = Files.createTempFile("dvai-test", ".task").toFile()
        try {
            val opts = StartOptions(backend = BackendKind.Auto, modelPath = tmp.absolutePath)
            assertEquals(BackendKind.MediaPipe, BackendSelector.resolve(opts))
        } finally {
            tmp.delete()
        }
    }

    @Test
    fun `auto with task suffix but missing file falls through to llama`() {
        val opts = StartOptions(
            backend = BackendKind.Auto,
            modelPath = "/tmp/does-not-exist-${System.nanoTime()}.task",
        )
        assertEquals(BackendKind.Llama, BackendSelector.resolve(opts))
    }

    @Test
    fun `auto with tflite suffix resolves to LiteRT`() {
        val opts = StartOptions(backend = BackendKind.Auto, modelPath = "/tmp/x.tflite")
        assertEquals(BackendKind.LiteRT, BackendSelector.resolve(opts))
    }

    @Test
    fun `auto with litertlm suffix resolves to LiteRT`() {
        val opts = StartOptions(backend = BackendKind.Auto, modelPath = "/tmp/x.litertlm")
        assertEquals(BackendKind.LiteRT, BackendSelector.resolve(opts))
    }

    @Test
    fun `auto with gguf suffix resolves to Llama`() {
        val opts = StartOptions(backend = BackendKind.Auto, modelPath = "/tmp/x.gguf")
        assertEquals(BackendKind.Llama, BackendSelector.resolve(opts))
    }

    @Test
    fun `auto with no modelPath defaults to Llama`() {
        val opts = StartOptions(backend = BackendKind.Auto, modelPath = null)
        assertEquals(BackendKind.Llama, BackendSelector.resolve(opts))
    }

    @Test
    fun `auto with unknown extension defaults to Llama`() {
        val opts = StartOptions(backend = BackendKind.Auto, modelPath = "/tmp/something.bin")
        assertEquals(BackendKind.Llama, BackendSelector.resolve(opts))
    }

    @Test
    fun `BackendKind enum order matches iOS counterpart`() {
        // Cross-platform spec compliance — the iOS DVAIBridge.BackendKind
        // declares cases in the same order: Auto, Llama, MediaPipe, LiteRT.
        // (Foundation / CoreML / MLX are iOS-only and don't appear here.)
        val expected = listOf("Auto", "Llama", "MediaPipe", "LiteRT")
        val actual = BackendKind.values().map { it.name }
        assertEquals(expected, actual)
    }
}
