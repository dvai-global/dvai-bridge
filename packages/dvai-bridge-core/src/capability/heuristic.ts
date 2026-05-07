/**
 * Coarse static fallback for the capability score before any cold-run
 * probe has run. The numbers below are deliberately conservative —
 * we'd rather under-promise local capability and offload more often
 * than over-promise and serve a slow stream.
 *
 * Refinement: the first real probe (capability/probe.ts) replaces
 * the heuristic with a measured value cached for that (model, version).
 */

import type { DeviceCapabilityHints } from "./types.js";

/**
 * Returns an estimated tok/s for the given hints. Pick the lowest
 * factor across the four dimensions — the bottleneck is what
 * actually limits inference speed.
 */
export function heuristicTokPerSec(hints: DeviceCapabilityHints): number {
  // Base score by GPU class. These numbers are based on observed
  // floors for common 1-3B GGUF q4 models in the wild.
  const gpuBase: Record<DeviceCapabilityHints["gpuClass"], number> = {
    "none": 3,           // CPU-only — very slow
    "integrated": 8,     // basic iGPU
    "discrete": 35,      // mid-range discrete (RTX 4060-class)
    "apple-silicon": 40, // M-series unified memory + Metal
  };

  // CPU class multiplier — affects prompt-processing more than
  // decode but still part of the picture.
  const cpuMul: Record<DeviceCapabilityHints["cpuClass"], number> = {
    "low": 0.6,
    "mid": 1.0,
    "high": 1.3,
  };

  // RAM penalty — under 4 GB you're probably swapping; under 8 GB
  // you can't run a 3B q4 model comfortably.
  let ramMul: number;
  if (hints.ramGb < 4) ramMul = 0.3;
  else if (hints.ramGb < 8) ramMul = 0.7;
  else ramMul = 1.0;

  // NPU bonus — only meaningful when the *backend* uses it (Foundation
  // Models on iOS, MediaPipe with QNN on Android). Conservative bonus
  // because not every backend benefits.
  const npuBonus = hints.hasNpu ? 1.4 : 1.0;

  const estimate = gpuBase[hints.gpuClass] * cpuMul[hints.cpuClass] * ramMul * npuBonus;
  // Round to one decimal to avoid spurious-precision noise.
  return Math.round(estimate * 10) / 10;
}

/**
 * Detect device hints from the current runtime. JS-side runs in
 * Node / browser; native SDKs supply richer hints via their own
 * platform-bridges.
 */
export function detectDeviceHints(): DeviceCapabilityHints {
  // Browser: rough guess from navigator (deviceMemory is in GB,
  // hardwareConcurrency is logical-core count). WebGPU presence is
  // a "discrete-ish" hint.
  if (typeof navigator !== "undefined") {
    const nav = navigator as Navigator & { deviceMemory?: number };
    const ramGb = nav.deviceMemory ?? 4;
    const cores = nav.hardwareConcurrency ?? 4;
    const hasGpu = typeof (nav as Navigator & { gpu?: unknown }).gpu !== "undefined";

    return {
      hasNpu: false, // browsers can't introspect NPU presence today
      ramGb,
      gpuClass: hasGpu ? "discrete" : "none",
      cpuClass: cores >= 8 ? "high" : cores >= 4 ? "mid" : "low",
    };
  }

  // Node / Electron-main: query os.totalmem + os.cpus().
  if (typeof globalThis.process !== "undefined" && globalThis.process.versions?.node) {
    // Dynamic import to avoid pulling node:os into browser bundles.
    // We can't await at module top level here, so return a
    // pessimistic default and let detectDeviceHintsAsync() refine.
  }

  // Default conservative bucket.
  return {
    hasNpu: false,
    ramGb: 4,
    gpuClass: "integrated",
    cpuClass: "mid",
  };
}

/**
 * Async variant — uses node:os when available. Prefer this in Node
 * contexts; the sync version is for browser fallback.
 */
export async function detectDeviceHintsAsync(): Promise<DeviceCapabilityHints> {
  if (typeof globalThis.process !== "undefined" && globalThis.process.versions?.node) {
    try {
      const os = await import("node:os");
      const totalMem = os.totalmem();
      const ramGb = Math.round(totalMem / (1024 ** 3));
      const cores = os.cpus().length;
      // Node can't introspect GPU class portably; default to
      // "integrated" unless the consumer overrides via config.
      return {
        hasNpu: false,
        ramGb,
        gpuClass: "integrated",
        cpuClass: cores >= 12 ? "high" : cores >= 6 ? "mid" : "low",
      };
    } catch {
      // node:os not available; fall through.
    }
  }
  return detectDeviceHints();
}
