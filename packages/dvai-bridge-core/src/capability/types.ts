/**
 * Phase 3 (v3.0) — capability assessment types.
 *
 * A "capability score" is an estimate of decode tok/s for a given
 * (model, device) pair on this device. Used by the offload decider
 * to pick local vs. peer execution per request.
 */

export interface CapabilityScore {
  /** Model identifier this score applies to. */
  modelId: string;
  /** Stable per-install device identifier. */
  deviceId: string;
  /** Library SemVer at the time the score was measured. */
  libraryVersion: string;
  /** Estimated decode rate, tokens-per-second. */
  tokPerSec: number;
  /** Source of the estimate. */
  source: "probe" | "heuristic";
  /** Unix milliseconds the score was measured / computed. */
  measuredAt: number;
}

/** Storage adapter for capability scores. Per-runtime concrete impls. */
export interface CapabilityCache {
  get(key: CapabilityCacheKey): Promise<CapabilityScore | undefined>;
  set(score: CapabilityScore): Promise<void>;
  list(): Promise<CapabilityScore[]>;
  clear(): Promise<void>;
}

export interface CapabilityCacheKey {
  modelId: string;
  libraryVersion: string;
}

/**
 * Coarse device-class buckets used by the heuristic fallback when no
 * cold-run probe has run yet. Numbers are intentionally conservative
 * — the probe will refine on first real use.
 */
export interface DeviceCapabilityHints {
  /** Has a dedicated NPU (Apple Neural Engine, Hexagon, Intel NPU, etc.) */
  hasNpu: boolean;
  /** Approximate system RAM in GB. */
  ramGb: number;
  /** GPU class — best-guess based on platform clues. */
  gpuClass: "none" | "integrated" | "discrete" | "apple-silicon";
  /** Coarse CPU bucket. */
  cpuClass: "low" | "mid" | "high";
}
