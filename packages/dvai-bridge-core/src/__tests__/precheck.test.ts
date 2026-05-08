/**
 * v3.2 — pre-init capability gate.
 *
 * Verifies that `assessCapability` correctly classifies devices into
 * the three lifecycle modes (`ok`, `offload-only`, `too-weak`) given
 * various hint shapes and threshold settings.
 */

import { describe, it, expect } from "vitest";
import {
  assessCapability,
  HardwareTooWeakError,
} from "../capability/precheck.js";
import type { DeviceCapabilityHints } from "../capability/types.js";

const HIGH_END_DESKTOP: DeviceCapabilityHints = {
  hasNpu: false,
  ramGb: 32,
  gpuClass: "discrete",
  cpuClass: "high",
};

const APPLE_SILICON_LAPTOP: DeviceCapabilityHints = {
  hasNpu: true,
  ramGb: 16,
  gpuClass: "apple-silicon",
  cpuClass: "high",
};

const MID_RANGE_LAPTOP: DeviceCapabilityHints = {
  hasNpu: false,
  ramGb: 8,
  gpuClass: "integrated",
  cpuClass: "mid",
};

const LOW_END_LAPTOP: DeviceCapabilityHints = {
  hasNpu: false,
  ramGb: 4,
  gpuClass: "integrated",
  cpuClass: "low",
};

const VERY_WEAK_DEVICE: DeviceCapabilityHints = {
  hasNpu: false,
  ramGb: 2,
  gpuClass: "none",
  cpuClass: "low",
};

describe("assessCapability", () => {
  it("classifies a high-end desktop as 'ok'", async () => {
    const result = await assessCapability({ hints: HIGH_END_DESKTOP });
    expect(result.mode).toBe("ok");
    expect(result.tokPerSec).toBeGreaterThan(10);
  });

  it("classifies Apple Silicon as 'ok'", async () => {
    const result = await assessCapability({ hints: APPLE_SILICON_LAPTOP });
    expect(result.mode).toBe("ok");
  });

  it("classifies a mid-range laptop as 'offload-only' at default thresholds", async () => {
    const result = await assessCapability({ hints: MID_RANGE_LAPTOP });
    // 8 (integrated) * 1.0 (mid CPU) * 1.0 (8 GB RAM) * 1.0 (no NPU) = 8 tok/s
    // → between hardwareMinimum (3) and minLocalCapability (10): offload-only
    expect(result.mode).toBe("offload-only");
    expect(result.tokPerSec).toBe(8);
  });

  it("classifies a low-end laptop as 'offload-only'", async () => {
    const result = await assessCapability({ hints: LOW_END_LAPTOP });
    // 8 * 0.6 * 0.7 = 3.4 tok/s → above floor (3), below comfort (10) → offload
    expect(result.mode).toBe("offload-only");
  });

  it("classifies a very-weak device as 'too-weak'", async () => {
    const result = await assessCapability({ hints: VERY_WEAK_DEVICE });
    // 3 (no GPU) * 0.6 (low CPU) * 0.3 (RAM < 4) = 0.5 tok/s → too-weak
    expect(result.mode).toBe("too-weak");
    expect(result.tokPerSec).toBeLessThan(3);
  });

  it("respects a custom hardwareMinimum", async () => {
    // Mid-range gets 8 tok/s. Raise the floor above that → too-weak.
    const result = await assessCapability({
      hints: MID_RANGE_LAPTOP,
      hardwareMinimum: 12,
    });
    expect(result.mode).toBe("too-weak");
  });

  it("respects a custom minLocalCapability", async () => {
    // Mid-range gets 8 tok/s. Lower the comfort threshold to 5 → ok.
    const result = await assessCapability({
      hints: MID_RANGE_LAPTOP,
      minLocalCapability: 5,
    });
    expect(result.mode).toBe("ok");
  });

  it("includes the hints + a human-readable reason in the result", async () => {
    const result = await assessCapability({ hints: VERY_WEAK_DEVICE });
    expect(result.hints).toEqual(VERY_WEAK_DEVICE);
    expect(result.reason).toMatch(/below the.*tok\/s/);
  });
});

describe("HardwareTooWeakError", () => {
  it("carries the structured fields", () => {
    const err = new HardwareTooWeakError({
      tokPerSec: 1,
      hardwareMinimum: 3,
      hints: VERY_WEAK_DEVICE,
      reason: "test",
    });
    expect(err.name).toBe("HardwareTooWeakError");
    expect(err.tokPerSec).toBe(1);
    expect(err.hardwareMinimum).toBe(3);
    expect(err.hints).toEqual(VERY_WEAK_DEVICE);
    expect(err.message).toContain("test");
  });
});
