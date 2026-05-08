package co.deepvoiceai.bridge.shared.core.capability

import android.app.ActivityManager
import android.content.Context
import android.os.Build
import kotlinx.serialization.Serializable

/**
 * v3.2 — pre-init capability gate for the Android SDK.
 *
 * Mirrors the TypeScript core's `assessCapability()` in
 * `@dvai-bridge/core/src/capability/precheck.ts`. The rule:
 *
 * Before any model download or backend init:
 *   - if estimated tok/s < hardwareMinimum (default 3) → mode=TOO_WEAK
 *     (host shows a system popup, SDK throws HardwareTooWeak; no
 *      model download happens).
 *   - else if estimated tok/s < minLocalCapability (default 10) →
 *     mode=OFFLOAD_ONLY (skip model load entirely; bring up only the
 *     proxy + discovery + pairing).
 *   - else → mode=OK (load locally + proxy + discovery).
 *
 * Heuristic-only — no model is loaded at this stage. A real probe
 * refines the estimate AFTER a model is loaded and a request has
 * actually run; that path is unchanged from v3.0.
 */
object CapabilityPrecheck {

    /** Result of [assess]. */
    @Serializable
    data class Result(
        val mode: PrecheckMode,
        /** Estimated decode tok/s on this device for any 1–3B model. */
        val tokPerSec: Double,
        val hints: DeviceCapabilityHints,
        /** Human-readable explanation; safe to log + display in UI. */
        val reason: String,
    )

    /** Tunable thresholds. */
    data class Thresholds(
        /** Below this, the device is too weak to run inference at all.
         *  Default 3.0 tok/s — anything below feels broken for chat. */
        val hardwareMinimum: Double = 3.0,
        /** Below this, run in offload-only mode. Default 10.0. */
        val minLocalCapability: Double = 10.0,
    )

    /** Run the precheck. [hints] override is for tests. */
    fun assess(
        context: Context,
        thresholds: Thresholds = Thresholds(),
        hints: DeviceCapabilityHints? = null,
    ): Result {
        val resolvedHints = hints ?: detectDeviceHints(context)
        val tokPerSec = heuristicTokPerSec(resolvedHints)

        return when {
            tokPerSec < thresholds.hardwareMinimum -> Result(
                mode = PrecheckMode.TOO_WEAK,
                tokPerSec = tokPerSec,
                hints = resolvedHints,
                reason = "estimated $tokPerSec tok/s, below the " +
                        "${thresholds.hardwareMinimum} tok/s hardware floor — " +
                        "local inference would be unusable.",
            )

            tokPerSec < thresholds.minLocalCapability -> Result(
                mode = PrecheckMode.OFFLOAD_ONLY,
                tokPerSec = tokPerSec,
                hints = resolvedHints,
                reason = "estimated $tokPerSec tok/s, below the " +
                        "${thresholds.minLocalCapability} tok/s comfort threshold — " +
                        "model will not be loaded locally; every request will be " +
                        "forwarded to a paired peer.",
            )

            else -> Result(
                mode = PrecheckMode.OK,
                tokPerSec = tokPerSec,
                hints = resolvedHints,
                reason = "estimated $tokPerSec tok/s, above the " +
                        "${thresholds.minLocalCapability} tok/s threshold — running normally.",
            )
        }
    }

    /** Pure heuristic — no Context needed; mirrors TS heuristicTokPerSec. */
    fun heuristicTokPerSec(hints: DeviceCapabilityHints): Double {
        // Base score by GPU class — observed floors for 1–3B q4 GGUFs.
        val gpuBase = when (hints.gpuClass) {
            GpuClass.NONE -> 3.0
            GpuClass.INTEGRATED -> 8.0
            GpuClass.DISCRETE -> 35.0
            GpuClass.APPLE_SILICON -> 40.0   // unused on Android but kept for parity
        }

        val cpuMul = when (hints.cpuClass) {
            CpuClass.LOW -> 0.6
            CpuClass.MID -> 1.0
            CpuClass.HIGH -> 1.3
        }

        val ramMul = when {
            hints.ramGb < 4 -> 0.3
            hints.ramGb < 8 -> 0.7
            else -> 1.0
        }

        val npuBonus = if (hints.hasNpu) 1.4 else 1.0

        val raw = gpuBase * cpuMul * ramMul * npuBonus
        return Math.round(raw * 10) / 10.0
    }

    /** Best-effort introspection from ActivityManager + Build properties. */
    fun detectDeviceHints(context: Context): DeviceCapabilityHints {
        val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val memInfo = ActivityManager.MemoryInfo()
        am.getMemoryInfo(memInfo)
        val ramGb = (memInfo.totalMem.toDouble() / (1024L * 1024 * 1024)).toInt()

        val cores = Runtime.getRuntime().availableProcessors()
        val cpuClass = when {
            cores >= 8 -> CpuClass.HIGH
            cores >= 4 -> CpuClass.MID
            else -> CpuClass.LOW
        }

        // Android phones don't have discrete GPUs — most have an integrated
        // mobile GPU (Adreno / Mali / PowerVR). Treat as INTEGRATED unless
        // the device is so old it doesn't even have one (rare in 2026+).
        val gpuClass = GpuClass.INTEGRATED

        // NPU detection: Pixel + Samsung + recent Qualcomm flagship phones
        // have NPUs (Tensor / Hexagon / etc.). Best signal we have without
        // a runtime probe is hardware/model name, but those strings are
        // unreliable across regions. Default false; the model-load probe
        // refines after first run.
        val hasNpu = false

        return DeviceCapabilityHints(
            hasNpu = hasNpu,
            ramGb = ramGb,
            gpuClass = gpuClass,
            cpuClass = cpuClass,
        )
    }
}

/** Parallels the TS `DeviceCapabilityHints` interface. */
@Serializable
data class DeviceCapabilityHints(
    val hasNpu: Boolean,
    val ramGb: Int,
    val gpuClass: GpuClass,
    val cpuClass: CpuClass,
)

@Serializable
enum class GpuClass {
    @kotlinx.serialization.SerialName("none") NONE,
    @kotlinx.serialization.SerialName("integrated") INTEGRATED,
    @kotlinx.serialization.SerialName("discrete") DISCRETE,
    @kotlinx.serialization.SerialName("apple-silicon") APPLE_SILICON,
}

@Serializable
enum class CpuClass {
    @kotlinx.serialization.SerialName("low") LOW,
    @kotlinx.serialization.SerialName("mid") MID,
    @kotlinx.serialization.SerialName("high") HIGH,
}

@Serializable
enum class PrecheckMode {
    OK,
    OFFLOAD_ONLY,
    TOO_WEAK,
}
