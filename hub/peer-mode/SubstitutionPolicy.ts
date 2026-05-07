/**
 * Phase 4 — DVAI Hub Substitution Policy.
 *
 * Decides which locally-cached backend (if any) to serve a request
 * with when the requesting app's model name doesn't exactly match
 * what the Hub has. Strict-by-default: refuses on any mismatch in
 * `family`, `version`, `size`, or `type`. Quant differences are the
 * only legitimate substitution axis, and even those are gated behind
 * the explicit `preferBetterQuant` opt-in (per-pairing or per-request).
 *
 * The policy never silently lies about which model was used: when it
 * returns a `substituted` decision, the caller MUST surface the
 * `replaced` field to the client so the consumer knows what was served.
 */

import {
  compareQuantQuality,
  sameModelShape,
  type ModelDescriptor,
} from "./ModelParser.js";

/** A backend that can serve a request — wraps the parsed descriptor of a cached model. */
export interface BackendDescriptor {
  /** Parsed view of the cached model — used for matching. */
  descriptor: ModelDescriptor;
  /** Which engine/adapter owns it (Hub builtin / Ollama / LM Studio / ...). */
  engine: string;
  /**
   * Opaque id the engine uses to address this model.
   * (For Ollama: the tag; for the builtin bridge: the original model id.)
   */
  engineModelId: string;
  /** Last-known performance score in tok/s (advisory only). */
  capabilityScore?: number;
}

export interface SubstitutionPolicyOptions {
  /**
   * If true, the policy may substitute a same-shape backend that has
   * a *better* (or worse) quant level. If false, only exact-quant
   * matches qualify. Default: false (strict).
   */
  preferBetterQuant: boolean;
}

export type SubstitutionRefuseReason =
  | "no_backends"
  | "family_mismatch"
  | "version_mismatch"
  | "size_mismatch"
  | "type_mismatch"
  | "quant_mismatch_strict";

export type RoutingDecision =
  | { kind: "exact"; backend: BackendDescriptor }
  | {
      kind: "substituted";
      backend: BackendDescriptor;
      replaced: { from: ModelDescriptor; to: ModelDescriptor };
      reason: "better_quant" | "lower_quant" | "exact_quant_unspecified";
      /** True when the substitute is *worse* quality than requested — caller SHOULD log a warning. */
      warning: boolean;
    }
  | { kind: "refuse"; reason: SubstitutionRefuseReason; detail?: string };

/**
 * Decides how to route a request given a list of available backends.
 *
 * Algorithm (priority order):
 *   1. Exact match (all 5 fields equal) → `exact`.
 *   2. Same shape (family + version + size + type) and same quant → `exact` (treat null===null as match).
 *   3. Same shape, quant differs:
 *        - If `preferBetterQuant: false` → refuse (`quant_mismatch_strict`).
 *        - If `preferBetterQuant: true` and a backend with strictly-better quant exists → `substituted/better_quant`.
 *        - If `preferBetterQuant: true` and only worse-quant backends exist → `substituted/lower_quant` (warning=true).
 *   4. Any shape mismatch → refuse with the most-specific field reason.
 */
export class SubstitutionPolicy {
  private readonly preferBetterQuant: boolean;

  constructor(opts: SubstitutionPolicyOptions) {
    this.preferBetterQuant = opts.preferBetterQuant;
  }

  pick(request: ModelDescriptor, available: BackendDescriptor[]): RoutingDecision {
    if (available.length === 0) {
      return { kind: "refuse", reason: "no_backends" };
    }

    // 1. Exact match — every field, including quant, equal.
    for (const b of available) {
      const d = b.descriptor;
      if (
        d.family === request.family &&
        d.version === request.version &&
        d.size === request.size &&
        d.type === request.type &&
        d.quant === request.quant
      ) {
        return { kind: "exact", backend: b };
      }
    }

    // 2. Same shape, quant unspecified in the request — match any quant.
    if (request.quant === null) {
      const sameShape = available.filter((b) => sameModelShape(b.descriptor, request));
      if (sameShape.length > 0) {
        // Prefer the highest-quality quant when caller didn't specify.
        const best = pickBestQuant(sameShape);
        return {
          kind: "substituted",
          backend: best,
          replaced: { from: request, to: best.descriptor },
          reason: "exact_quant_unspecified",
          warning: false,
        };
      }
    }

    // 3. Same shape, quant differs — gated by preferBetterQuant.
    const sameShape = available.filter((b) => sameModelShape(b.descriptor, request));
    if (sameShape.length > 0) {
      if (!this.preferBetterQuant) {
        return {
          kind: "refuse",
          reason: "quant_mismatch_strict",
          detail: `Request quant=${request.quant ?? "null"}; available quants=${sameShape
            .map((b) => b.descriptor.quant ?? "null")
            .join(",")}; preferBetterQuant is false.`,
        };
      }

      // preferBetterQuant === true. Find a backend with strictly-better quant.
      const better = sameShape.filter(
        (b) => compareQuantQuality(b.descriptor.quant, request.quant) > 0,
      );
      if (better.length > 0) {
        const pick = pickBestQuant(better);
        return {
          kind: "substituted",
          backend: pick,
          replaced: { from: request, to: pick.descriptor },
          reason: "better_quant",
          warning: false,
        };
      }

      // No better-quant option — fall back to any same-shape with same quant family,
      // including worse. Warn the caller so they can audit-log it.
      const pick = pickBestQuant(sameShape);
      return {
        kind: "substituted",
        backend: pick,
        replaced: { from: request, to: pick.descriptor },
        reason: "lower_quant",
        warning: true,
      };
    }

    // 4. No shape match — refuse with the most-specific field reason.
    return refuseWithMostSpecificMismatch(request, available);
  }
}

/** Among same-shape backends, return the one with the highest QUANT_ORDER index. */
function pickBestQuant(backends: BackendDescriptor[]): BackendDescriptor {
  if (backends.length === 0) {
    throw new Error("pickBestQuant called with empty list");
  }
  let best = backends[0]!;
  for (let i = 1; i < backends.length; i++) {
    const cand = backends[i]!;
    if (compareQuantQuality(cand.descriptor.quant, best.descriptor.quant) > 0) {
      best = cand;
    }
  }
  return best;
}

/**
 * When no same-shape backend exists, pick the most-specific mismatch
 * reason to surface to the caller — type > size > version > family,
 * because closer mismatches tell the user more about what's wrong.
 */
function refuseWithMostSpecificMismatch(
  request: ModelDescriptor,
  available: BackendDescriptor[],
): RoutingDecision {
  // Walk available, find the closest near-miss (most matching fields)
  // and return the FIRST mismatching field as the reason.
  let bestScore = -1;
  let bestReason: SubstitutionRefuseReason = "family_mismatch";
  let bestDetail = "";

  for (const b of available) {
    const d = b.descriptor;
    const familyMatch = d.family === request.family;
    const versionMatch = d.version === request.version;
    const sizeMatch = d.size === request.size;
    const typeMatch = d.type === request.type;

    let score = 0;
    if (familyMatch) score++;
    if (versionMatch) score++;
    if (sizeMatch) score++;
    if (typeMatch) score++;

    if (score <= bestScore) continue;
    bestScore = score;

    let reason: SubstitutionRefuseReason;
    if (!familyMatch) {
      reason = "family_mismatch";
    } else if (!versionMatch) {
      reason = "version_mismatch";
    } else if (!sizeMatch) {
      reason = "size_mismatch";
    } else if (!typeMatch) {
      reason = "type_mismatch";
    } else {
      // All four matched but we got here from "no same-shape found" — should be unreachable.
      reason = "quant_mismatch_strict";
    }
    bestReason = reason;
    bestDetail = `Request: family=${request.family} version=${request.version ?? "null"} size=${request.size} type=${request.type}; closest available: family=${d.family} version=${d.version ?? "null"} size=${d.size} type=${d.type}.`;
  }

  return { kind: "refuse", reason: bestReason, detail: bestDetail };
}
