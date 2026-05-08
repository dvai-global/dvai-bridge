/**
 * v3.2 — pre-init capability gate.
 *
 * Runs BEFORE any model download or backend init. Decides whether the
 * device should:
 *
 *   1. Refuse to run inference at all (hardware too weak).
 *      Triggers a host-supplied `onHardwareTooWeak` callback so the
 *      consumer can show a system popup, then throws so initialize()
 *      aborts cleanly.
 *
 *   2. Run in offload-only mode (capable enough to bridge but not to
 *      run the model itself comfortably). The SDK skips the model
 *      download/load entirely and only brings up the proxy + discovery
 *      + pairing layer. Every request gets forwarded to a paired peer;
 *      503 + Retry-After if no peer is available.
 *
 *   3. Run normally (load the model locally + run discovery/pairing
 *      so this device can also serve other peers if it's strong).
 *
 * The decision uses ONLY the heuristic (CPU/GPU/RAM hints) — no model
 * is needed at this stage. Refinement via a real probe happens later,
 * after the model has been loaded and a request has actually completed.
 */

import {
  detectDeviceHintsAsync,
  heuristicTokPerSec,
} from "./heuristic.js";
import type { DeviceCapabilityHints } from "./types.js";

/** Result of a pre-init capability assessment. */
export type PrecheckResult =
  | { mode: "ok"; tokPerSec: number; hints: DeviceCapabilityHints; reason: string }
  | { mode: "offload-only"; tokPerSec: number; hints: DeviceCapabilityHints; reason: string }
  | { mode: "too-weak"; tokPerSec: number; hints: DeviceCapabilityHints; reason: string };

export interface PrecheckOptions {
  /**
   * Hard floor for any local inference, in tok/s. Below this, the
   * device is too weak to be useful at all and the precheck returns
   * `mode: "too-weak"`. Default: 3.
   *
   * Apps that want to allow even slower inference (e.g. for
   * long-prompt summarization where latency is acceptable) can pass
   * a smaller value. Apps targeting interactive chat should leave
   * the default — anything below ~3 tok/s feels broken.
   */
  hardwareMinimum?: number;

  /**
   * Below this tok/s but above `hardwareMinimum`, run in offload-only
   * mode (skip model load; route every request to a paired peer).
   * Above this, load locally. Default: pulled from
   * `OffloadConfig.minLocalCapability` if not set.
   */
  minLocalCapability?: number;

  /**
   * Pre-detected hints. Tests pass synthetic values here. In
   * production, leave undefined and let the precheck call
   * `detectDeviceHintsAsync()` itself.
   */
  hints?: DeviceCapabilityHints;
}

const DEFAULT_HARDWARE_MINIMUM = 3;
const DEFAULT_MIN_LOCAL_CAPABILITY = 10;

export async function assessCapability(
  opts: PrecheckOptions = {},
): Promise<PrecheckResult> {
  const hardwareMinimum = opts.hardwareMinimum ?? DEFAULT_HARDWARE_MINIMUM;
  const minLocalCapability = opts.minLocalCapability ?? DEFAULT_MIN_LOCAL_CAPABILITY;

  if (hardwareMinimum > minLocalCapability) {
    // Allowed but odd — the offload-only band collapses to zero.
    // Useful for "load locally if you can or refuse" deployments.
  }

  const hints = opts.hints ?? (await detectDeviceHintsAsync());
  const tokPerSec = heuristicTokPerSec(hints);

  if (tokPerSec < hardwareMinimum) {
    return {
      mode: "too-weak",
      tokPerSec,
      hints,
      reason:
        `estimated ${tokPerSec} tok/s, below the ${hardwareMinimum} tok/s ` +
        `hardware floor — local inference would be unusable, no peer to ` +
        `offload to either (a peer-only mode still requires the host to ` +
        `bring up discovery + pairing).`,
    };
  }

  if (tokPerSec < minLocalCapability) {
    return {
      mode: "offload-only",
      tokPerSec,
      hints,
      reason:
        `estimated ${tokPerSec} tok/s, below the ${minLocalCapability} tok/s ` +
        `comfort threshold — model will not be loaded locally; every ` +
        `request will be forwarded to a paired peer.`,
    };
  }

  return {
    mode: "ok",
    tokPerSec,
    hints,
    reason:
      `estimated ${tokPerSec} tok/s, above the ${minLocalCapability} tok/s ` +
      `local-capability threshold — running normally.`,
  };
}

/**
 * @deprecated v3.2 — kept only to avoid breaking type imports. The
 * SDK no longer throws on too-weak hardware; consumers call
 * `dvai.assessHardware()` and decide their own UI. start() in a
 * too-weak case enters offload-only mode silently (no model
 * download/load).
 *
 * Will be removed in v4.0.
 */
export class HardwareTooWeakError extends Error {
  readonly tokPerSec: number;
  readonly hardwareMinimum: number;
  readonly hints: DeviceCapabilityHints;

  constructor(opts: {
    tokPerSec: number;
    hardwareMinimum: number;
    hints: DeviceCapabilityHints;
    reason: string;
  }) {
    super(`DVAI: ${opts.reason}`);
    this.name = "HardwareTooWeakError";
    this.tokPerSec = opts.tokPerSec;
    this.hardwareMinimum = opts.hardwareMinimum;
    this.hints = opts.hints;
  }
}
