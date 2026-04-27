package co.deepvoiceai.bridge

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.reflect.full.functions
import kotlin.reflect.full.memberProperties

/**
 * Reflection-based smoke checks on the public DVAIBridge surface. These
 * don't actually invoke the bridge — they just assert the 8 expected
 * public methods + properties exist with the right shape.
 *
 * The point: prevent accidental rename / removal of public API across
 * cross-platform parity refactors. Compare against
 * `packages/dvai-bridge-ios/ios/Sources/DVAIBridge/DVAIBridge.swift`.
 */
class DVAIBridgeAPIShapeTest {
    @Test
    fun `singleton is the DVAIBridge object`() {
        val instance = DVAIBridge
        assertNotNull(instance)
    }

    @Test
    fun `public methods include start stop status init downloadModel listeners`() {
        val fnNames = DVAIBridge::class.functions.map { it.name }.toSet()
        for (expected in listOf(
            "init",
            "start",
            "stop",
            "status",
            "downloadModel",
            "addProgressListener",
            "removeProgressListener",
        )) {
            assertTrue("missing method: $expected (had: $fnNames)", expected in fnNames)
        }
    }

    @Test
    fun `public properties include progressFlow and reactive`() {
        val propNames = DVAIBridge::class.memberProperties.map { it.name }.toSet()
        for (expected in listOf("progressFlow", "reactive")) {
            assertTrue("missing property: $expected (had: $propNames)", expected in propNames)
        }
    }

    @Test
    fun `BackendKind has the expected 4 cases`() {
        // Cross-platform parity: same 4 cases as the iOS Android-relevant
        // subset (iOS adds Foundation / CoreML / MLX which don't exist on
        // Android; Android's MediaPipe / LiteRT don't exist on iOS).
        assertEquals(4, BackendKind.values().size)
    }

    @Test
    fun `StartOptions defaults match iOS DVAIBridgeConfig defaults`() {
        val opts = StartOptions()
        assertEquals(BackendKind.Auto, opts.backend)
        assertEquals(2048, opts.contextSize)
        assertEquals(4, opts.threads)
        assertEquals(38883, opts.httpBasePort)
        assertEquals(16, opts.httpMaxPortAttempts)
        assertEquals(99, opts.gpuLayers)
        assertEquals(512, opts.maxNewTokens)
    }

    @Test
    fun `DVAIBridgeError sealed class has expected cases`() {
        // Sanity-check error case names — consumer try-catch blocks should
        // be able to pattern-match on each of these.
        val expected = setOf(
            "AlreadyStarted",
            "ConfigurationInvalid",
            "ModelLoadFailed",
            "BackendUnavailable",
            "BackendError",
            "ChecksumMismatch",
            "DownloadFailed",
        )
        val actual = DVAIBridgeError::class.sealedSubclasses.map { it.simpleName }.toSet()
        assertEquals(expected, actual)
    }
}
