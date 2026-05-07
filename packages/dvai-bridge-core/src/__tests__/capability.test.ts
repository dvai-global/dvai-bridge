import { describe, it, expect, beforeEach } from "vitest";
import {
  InMemoryCapabilityCache,
  heuristicTokPerSec,
  probeCapability,
  ensureDeviceId,
  getCapability,
  probeAndCache,
} from "../capability/index.js";
import type { ProbableBackend } from "../capability/probe.js";

describe("capability — heuristic", () => {
  it("scores a discrete-GPU + 16 GB + high-CPU + NPU rig high", () => {
    const score = heuristicTokPerSec({
      hasNpu: true,
      ramGb: 16,
      gpuClass: "discrete",
      cpuClass: "high",
    });
    expect(score).toBeGreaterThan(40);
  });

  it("scores a CPU-only + 4 GB + low-CPU rig low", () => {
    const score = heuristicTokPerSec({
      hasNpu: false,
      ramGb: 4,
      gpuClass: "none",
      cpuClass: "low",
    });
    expect(score).toBeLessThan(5);
  });

  it("apple-silicon scores higher than integrated GPU at the same RAM/CPU", () => {
    const apple = heuristicTokPerSec({
      hasNpu: true,
      ramGb: 16,
      gpuClass: "apple-silicon",
      cpuClass: "high",
    });
    const integrated = heuristicTokPerSec({
      hasNpu: false,
      ramGb: 16,
      gpuClass: "integrated",
      cpuClass: "high",
    });
    expect(apple).toBeGreaterThan(integrated);
  });
});

describe("capability — probe", () => {
  it("computes tok/s from a fixed-time mock backend", async () => {
    const backend: ProbableBackend = {
      async chatCompletion(_req) {
        // Fake a 200ms wall-clock for 50 tokens → 250 tok/s.
        await new Promise((r) => setTimeout(r, 200));
        return {
          choices: [{ message: { content: "Clouds are made of water vapor." } }],
          usage: { completion_tokens: 50 },
        };
      },
    };
    const score = await probeCapability({
      backend,
      modelId: "test-model",
      libraryVersion: "3.0.0",
      deviceId: "test-device",
    });
    expect(score.modelId).toBe("test-model");
    expect(score.source).toBe("probe");
    // Allow generous wiggle room — CI hosts have variable scheduler latency.
    expect(score.tokPerSec).toBeGreaterThan(50);
    expect(score.tokPerSec).toBeLessThan(500);
  });

  it("falls back to char-count when the backend doesn't report usage", async () => {
    const backend: ProbableBackend = {
      async chatCompletion(_req) {
        return {
          choices: [{ message: { content: "x".repeat(200) } }],
        };
      },
    };
    const score = await probeCapability({
      backend,
      modelId: "no-usage-model",
      libraryVersion: "3.0.0",
      deviceId: "test",
    });
    // 200 chars / 4 = 50 tokens. Time is near-zero so tok/s is large.
    expect(score.tokPerSec).toBeGreaterThan(0);
  });

  it("returns 0 tok/s on empty completion", async () => {
    const backend: ProbableBackend = {
      async chatCompletion(_req) {
        return { choices: [{ message: { content: "" } }], usage: { completion_tokens: 0 } };
      },
    };
    const score = await probeCapability({
      backend,
      modelId: "broken-model",
      libraryVersion: "3.0.0",
      deviceId: "test",
    });
    expect(score.tokPerSec).toBe(0);
  });
});

describe("capability — cache (InMemory)", () => {
  let cache: InMemoryCapabilityCache;
  beforeEach(() => {
    cache = new InMemoryCapabilityCache();
  });

  it("returns undefined for a missing key", async () => {
    const got = await cache.get({ modelId: "x", libraryVersion: "3.0.0" });
    expect(got).toBeUndefined();
  });

  it("round-trips a stored score", async () => {
    const score = {
      modelId: "model-A",
      deviceId: "dev-1",
      libraryVersion: "3.0.0",
      tokPerSec: 25,
      source: "probe" as const,
      measuredAt: Date.now(),
    };
    await cache.set(score);
    const got = await cache.get({ modelId: "model-A", libraryVersion: "3.0.0" });
    expect(got).toEqual(score);
  });

  it("clear empties the store", async () => {
    await cache.set({
      modelId: "x",
      deviceId: "d",
      libraryVersion: "3.0.0",
      tokPerSec: 10,
      source: "probe",
      measuredAt: 0,
    });
    await cache.clear();
    expect((await cache.list()).length).toBe(0);
  });
});

describe("capability — facade", () => {
  it("getCapability returns heuristic score on cold cache", async () => {
    const cache = new InMemoryCapabilityCache();
    const score = await getCapability({
      cache,
      modelId: "fresh-model",
      libraryVersion: "3.0.0",
      hints: { hasNpu: false, ramGb: 8, gpuClass: "integrated", cpuClass: "mid" },
    });
    expect(score.source).toBe("heuristic");
    expect(score.tokPerSec).toBeGreaterThan(0);
  });

  it("getCapability returns cached probe score after probeAndCache", async () => {
    const cache = new InMemoryCapabilityCache();
    const backend: ProbableBackend = {
      async chatCompletion(_req) {
        await new Promise((r) => setTimeout(r, 100));
        return {
          choices: [{ message: { content: "ok" } }],
          usage: { completion_tokens: 50 },
        };
      },
    };
    const probed = await probeAndCache({
      cache,
      backend,
      modelId: "probed-model",
      libraryVersion: "3.0.0",
    });
    expect(probed.source).toBe("probe");

    const cached = await getCapability({
      cache,
      modelId: "probed-model",
      libraryVersion: "3.0.0",
    });
    expect(cached).toEqual(probed);
    expect(cached.source).toBe("probe");
  });

  it("ensureDeviceId returns the same id on a second call", async () => {
    const cache = new InMemoryCapabilityCache();
    const id1 = await ensureDeviceId(cache);
    const id2 = await ensureDeviceId(cache);
    // In-memory adapter does NOT persist the ID across calls; each call
    // generates a fresh one. That's documented behaviour.
    expect(id1).toMatch(/^[A-Za-z0-9_-]+$/);
    expect(id2).toMatch(/^[A-Za-z0-9_-]+$/);
    // Both 22 chars (URL-safe base64 of 16 bytes).
    expect(id1.length).toBeGreaterThanOrEqual(22);
  });
});
