/**
 * Tests for the per-adapter cache mutex in EngineBridge.
 *
 * The race we're guarding against:
 *   T0: UI clicks "Rescan Engine" → invalidateCache("ollama")
 *   T1: A paired mobile peer's `routeRequest` fires `enumerateAvailable`
 *
 * Both call paths probe + write the cache for "ollama". Pre-mutex, the
 * later write would clobber the earlier one — and the order was
 * effectively random, leading to "click Rescan, engine flips to offline"
 * even when the engine was running, and "Last Scan" time blanking out.
 *
 * Post-mutex, writes for a single adapter are serialised; whichever
 * call arrives second observes the prior call's effects before adding
 * its own.
 */
import { describe, it, expect } from "vitest";
import { EngineBridge, type EngineAdapter, type ChatResponse } from "../peer-mode/EngineBridge.js";

/**
 * An adapter whose `detect()` resolves only when externally signalled.
 * Lets the test pause one detection mid-flight while triggering a
 * second concurrent detect — exposing any cache-write race.
 */
function controllableAdapter(name: string): {
  adapter: EngineAdapter;
  detectCount: () => number;
  releaseNext: () => void;
  releaseAll: () => void;
} {
  let pending: Array<() => void> = [];
  let detectCount = 0;
  let detectResult = true;

  const adapter: EngineAdapter = {
    name,
    detect: async () => {
      detectCount++;
      // Capture our resolver and wait for the test to release it.
      return new Promise<boolean>((resolve) => {
        pending.push(() => resolve(detectResult));
      });
    },
    enumerateCachedModels: async () => [],
    serveRequest: async (): Promise<ChatResponse> => ({ status: 200, headers: {}, body: {} }),
    close: async () => undefined,
  };

  return {
    adapter,
    detectCount: () => detectCount,
    releaseNext: () => {
      const next = pending.shift();
      next?.();
    },
    releaseAll: () => {
      const all = pending;
      pending = [];
      for (const r of all) r();
    },
  };
}

describe("EngineBridge — per-adapter mutex", () => {
  it("serialises concurrent rescan + enumerateAvailable on the same adapter", async () => {
    const ctl = controllableAdapter("ollama");
    const bridge = new EngineBridge({
      enabled: true,
      adapters: [ctl.adapter],
      cacheTtlMs: 0, // make every enumerate go through the stale path
    });

    // Start the bridge — this kicks off the first detect call, which is
    // suspended in our controllable adapter. We need to release it so
    // start() can resolve.
    const startP = bridge.start();
    // Allow the start probe to land.
    await new Promise((r) => setImmediate(r));
    ctl.releaseNext();
    await startP;
    expect(ctl.detectCount()).toBe(1);

    // Now kick off two concurrent operations on the same adapter:
    //   - a rescan (writes the cache)
    //   - an enumerate (also writes the cache because TTL=0)
    // The pre-mutex implementation could have either complete second,
    // leaving the other's result behind. With the mutex they serialise.
    const rescanP = bridge.invalidateCache("ollama");
    const enumerateP = bridge.enumerateAvailable();
    // Both should now be queued behind the mutex. Only one detect call
    // should have started — the other waits.
    await new Promise((r) => setImmediate(r));
    expect(ctl.detectCount()).toBe(2);

    // Release the first, then the second.
    ctl.releaseNext();
    await new Promise((r) => setImmediate(r));
    expect(ctl.detectCount()).toBe(3);
    ctl.releaseNext();

    await Promise.all([rescanP, enumerateP]);

    // Final state: detected, and the cache reflects whichever scan
    // landed last (both produced the same result, so the contents are
    // deterministic). The mutex guarantees no torn writes.
    const summaries = bridge.detected();
    expect(summaries[0]?.detected).toBe(true);
    expect(summaries[0]?.lastEnumeratedAt).toBeGreaterThan(0);

    await bridge.stop();
  });

  it("preserves enumeratedAt timestamp through concurrent operations", async () => {
    // Regression case for the UI symptom: rescan blanked "Last Scan"
    // time. The mutex must guarantee a fresh enumeratedAt after every
    // successful detect, even when calls race.
    const ctl = controllableAdapter("ollama");
    const bridge = new EngineBridge({
      enabled: true,
      adapters: [ctl.adapter],
    });

    const startP = bridge.start();
    await new Promise((r) => setImmediate(r));
    ctl.releaseNext();
    await startP;

    const beforeRescan = bridge.detected()[0]?.lastEnumeratedAt ?? 0;
    expect(beforeRescan).toBeGreaterThan(0);

    // Wait a tick so the post-rescan timestamp is strictly greater.
    await new Promise((r) => setTimeout(r, 5));

    const rescanP = bridge.invalidateCache("ollama");
    await new Promise((r) => setImmediate(r));
    ctl.releaseNext();
    await rescanP;

    const afterRescan = bridge.detected()[0]?.lastEnumeratedAt ?? 0;
    expect(afterRescan).toBeGreaterThan(beforeRescan);

    await bridge.stop();
  });
});
