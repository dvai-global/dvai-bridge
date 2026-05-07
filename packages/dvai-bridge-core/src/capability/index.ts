/**
 * Phase 3 — capability assessment surface.
 *
 * Public facade glued together from the building blocks in this dir:
 *   - probe.ts: cold-run measurement
 *   - heuristic.ts: static fallback before first probe
 *   - cache.ts: persistent storage adapters
 *   - deviceId.ts: stable per-install ID
 *
 * Wired into DVAI in src/index.ts as `dvai.probeCapability()` and
 * `dvai.getCapability(modelId)`. The offload decider in src/offload/
 * is the primary consumer.
 */

import {
  IndexedDBCapabilityCache,
  NodeFsCapabilityCache,
  createCapabilityCache,
  InMemoryCapabilityCache,
} from "./cache.js";
import { detectDeviceHints, detectDeviceHintsAsync, heuristicTokPerSec } from "./heuristic.js";
import { generateDeviceId } from "./deviceId.js";
import { probeCapability, type ProbableBackend } from "./probe.js";
import type { CapabilityCache, CapabilityScore, DeviceCapabilityHints } from "./types.js";

export type { CapabilityScore, CapabilityCache, DeviceCapabilityHints, ProbableBackend };

export {
  IndexedDBCapabilityCache,
  NodeFsCapabilityCache,
  InMemoryCapabilityCache,
  createCapabilityCache,
  heuristicTokPerSec,
  detectDeviceHints,
  detectDeviceHintsAsync,
  generateDeviceId,
  probeCapability,
};

const DEVICE_ID_META_KEY = "dvai.deviceId";

/**
 * Resolve (or generate-on-first-call + persist) the per-install
 * device ID. The cache adapter is responsible for the persistence;
 * this function unifies the IndexedDB / Node-FS access patterns.
 */
export async function ensureDeviceId(cache: CapabilityCache): Promise<string> {
  // IndexedDB adapter has its own getMeta/setMeta for the meta store.
  if (cache instanceof IndexedDBCapabilityCache) {
    const existing = await cache.getMeta(DEVICE_ID_META_KEY);
    if (existing) return existing;
    const fresh = generateDeviceId();
    await cache.setMeta(DEVICE_ID_META_KEY, fresh);
    return fresh;
  }
  // Node FS adapter has dedicated getDeviceId/setDeviceId on the
  // backing JSON file.
  if (cache instanceof NodeFsCapabilityCache) {
    const existing = await cache.getDeviceId();
    if (existing) return existing;
    const fresh = generateDeviceId();
    await cache.setDeviceId(fresh);
    return fresh;
  }
  // In-memory adapter — generate but don't persist (ephemeral).
  const fresh = generateDeviceId();
  return fresh;
}

/**
 * Get the capability score for a model on this device. Returns the
 * cached probe result if available; otherwise the static heuristic
 * estimate (marked source: "heuristic"). Does NOT trigger a probe —
 * call probeAndCache separately to measure.
 */
export async function getCapability(opts: {
  cache: CapabilityCache;
  modelId: string;
  libraryVersion: string;
  hints?: DeviceCapabilityHints;
}): Promise<CapabilityScore> {
  const cached = await opts.cache.get({
    modelId: opts.modelId,
    libraryVersion: opts.libraryVersion,
  });
  if (cached) return cached;

  const hints = opts.hints ?? (await detectDeviceHintsAsync());
  const deviceId = await ensureDeviceId(opts.cache);

  return {
    modelId: opts.modelId,
    deviceId,
    libraryVersion: opts.libraryVersion,
    tokPerSec: heuristicTokPerSec(hints),
    source: "heuristic",
    measuredAt: Date.now(),
  };
}

/**
 * Run a cold-run probe against the given backend, persist the result,
 * and return the new score.
 */
export async function probeAndCache(opts: {
  cache: CapabilityCache;
  backend: ProbableBackend;
  modelId: string;
  libraryVersion: string;
}): Promise<CapabilityScore> {
  const deviceId = await ensureDeviceId(opts.cache);
  const score = await probeCapability({
    backend: opts.backend,
    modelId: opts.modelId,
    libraryVersion: opts.libraryVersion,
    deviceId,
  });
  await opts.cache.set(score);
  return score;
}

/** Drop all cached scores. Useful for diagnostics + tests. */
export async function clearCapabilityCache(cache: CapabilityCache): Promise<void> {
  await cache.clear();
}
