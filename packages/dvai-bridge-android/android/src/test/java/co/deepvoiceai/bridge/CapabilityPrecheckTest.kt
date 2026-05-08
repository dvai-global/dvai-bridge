package co.deepvoiceai.bridge

import co.deepvoiceai.bridge.shared.core.capability.CapabilityPrecheck
import co.deepvoiceai.bridge.shared.core.capability.CpuClass
import co.deepvoiceai.bridge.shared.core.capability.DeviceCapabilityHints
import co.deepvoiceai.bridge.shared.core.capability.GpuClass
import co.deepvoiceai.bridge.shared.core.capability.PrecheckMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * v3.2 — pre-init capability gate (Kotlin).
 *
 * Mirrors `packages/dvai-bridge-core/src/__tests__/precheck.test.ts`
 * one-to-one. Same hints, same expected modes — guarantees that the
 * Android SDK and the TS core agree on what's a "too-weak" or
 * "offload-only" device for a given hardware shape.
 *
 * Heuristic-only: no real device call. Pass [DeviceCapabilityHints]
 * directly to [CapabilityPrecheck.assess] via the `hints` override.
 * Robolectric provides the ApplicationContext (the assess() function
 * needs one even when hints are pre-supplied — for consistency with
 * the auto-detect path).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class CapabilityPrecheckTest {

    private val ctx: android.content.Context get() = RuntimeEnvironment.getApplication()

    private val highEndDesktop = DeviceCapabilityHints(
        hasNpu = false, ramGb = 32, gpuClass = GpuClass.DISCRETE, cpuClass = CpuClass.HIGH,
    )
    private val appleSiliconLaptop = DeviceCapabilityHints(
        hasNpu = true, ramGb = 16, gpuClass = GpuClass.APPLE_SILICON, cpuClass = CpuClass.HIGH,
    )
    private val midRangeLaptop = DeviceCapabilityHints(
        hasNpu = false, ramGb = 8, gpuClass = GpuClass.INTEGRATED, cpuClass = CpuClass.MID,
    )
    private val lowEndLaptop = DeviceCapabilityHints(
        hasNpu = false, ramGb = 4, gpuClass = GpuClass.INTEGRATED, cpuClass = CpuClass.LOW,
    )
    private val veryWeakDevice = DeviceCapabilityHints(
        hasNpu = false, ramGb = 2, gpuClass = GpuClass.NONE, cpuClass = CpuClass.LOW,
    )

    @Test
    fun `high-end desktop classifies as OK`() {
        val result = CapabilityPrecheck.assess(ctx, hints = highEndDesktop)
        assertEquals(PrecheckMode.OK, result.mode)
        assertTrue("expected > 10 tok/s, got ${result.tokPerSec}", result.tokPerSec > 10.0)
    }

    @Test
    fun `Apple Silicon classifies as OK`() {
        val result = CapabilityPrecheck.assess(ctx, hints = appleSiliconLaptop)
        assertEquals(PrecheckMode.OK, result.mode)
    }

    @Test
    fun `mid-range laptop classifies as OFFLOAD_ONLY at default thresholds`() {
        // 8 (integrated) * 1.0 (mid CPU) * 1.0 (8 GB RAM) * 1.0 (no NPU) = 8 tok/s
        // Above hardwareMinimum (3), below minLocalCapability (10) ⇒ offload-only.
        val result = CapabilityPrecheck.assess(ctx, hints = midRangeLaptop)
        assertEquals(PrecheckMode.OFFLOAD_ONLY, result.mode)
        assertEquals(8.0, result.tokPerSec, 0.01)
    }

    @Test
    fun `low-end laptop classifies as OFFLOAD_ONLY`() {
        // 8 * 0.6 * 0.7 = 3.4 tok/s ⇒ above floor (3), below comfort (10).
        val result = CapabilityPrecheck.assess(ctx, hints = lowEndLaptop)
        assertEquals(PrecheckMode.OFFLOAD_ONLY, result.mode)
    }

    @Test
    fun `very-weak device classifies as TOO_WEAK`() {
        // 3 (no GPU) * 0.6 (low CPU) * 0.3 (RAM < 4) = 0.5 tok/s ⇒ too-weak.
        val result = CapabilityPrecheck.assess(ctx, hints = veryWeakDevice)
        assertEquals(PrecheckMode.TOO_WEAK, result.mode)
        assertTrue(result.tokPerSec < 3.0)
    }

    @Test
    fun `custom hardwareMinimum is honored`() {
        val result = CapabilityPrecheck.assess(
            ctx,
            thresholds = CapabilityPrecheck.Thresholds(hardwareMinimum = 12.0),
            hints = midRangeLaptop,
        )
        assertEquals(PrecheckMode.TOO_WEAK, result.mode)
    }

    @Test
    fun `custom minLocalCapability is honored`() {
        val result = CapabilityPrecheck.assess(
            ctx,
            thresholds = CapabilityPrecheck.Thresholds(minLocalCapability = 5.0),
            hints = midRangeLaptop,
        )
        assertEquals(PrecheckMode.OK, result.mode)
    }

    @Test
    fun `result reason mentions tok-per-second`() {
        val result = CapabilityPrecheck.assess(ctx, hints = veryWeakDevice)
        assertTrue(
            "reason should mention tok/s — got: ${result.reason}",
            result.reason.contains("tok/s"),
        )
    }
}
