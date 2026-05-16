package co.deepvoiceai.bridge.shared.core.capability

import kotlinx.serialization.Serializable

/**
 * Phase 3 — capability score (Kotlin mirror of `CapabilityScore` in
 * `@dvai-bridge/core/src/capability/types.ts`).
 *
 * A "capability score" is an estimate of decode tok/s for a given
 * (model, device) pair on this device. Used by the offload decider
 * to pick local vs. peer execution per request.
 */
@Serializable
data class CapabilityScore(
    /** Model identifier this score applies to. */
    val modelId: String,
    /** Stable per-install device identifier. */
    val deviceId: String,
    /** Library SemVer at the time the score was measured. */
    val libraryVersion: String,
    /** Estimated decode rate, tokens-per-second. */
    val tokPerSec: Double,
    /** Source of the estimate. */
    val source: ScoreSource,
    /** Unix milliseconds the score was measured / computed. */
    val measuredAt: Long,
)

@Serializable
enum class ScoreSource {
    @kotlinx.serialization.SerialName("probe")
    PROBE,
    @kotlinx.serialization.SerialName("heuristic")
    HEURISTIC,
}

/** Composite key for [CapabilityCache] — mirrors the TS `CapabilityCacheKey`. */
data class CapabilityCacheKey(
    val modelId: String,
    val libraryVersion: String,
)
