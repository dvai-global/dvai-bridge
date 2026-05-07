/**
 * Pure offload decision function. Tested in isolation; called by the
 * proxy on every chat-completion request.
 */

import type { Peer } from "../discovery/types.js";
import type { Decision, OffloadConfig, OffloadHeader, PeerCheckResult } from "./types.js";

export interface DecideInput {
  config: OffloadConfig;
  modelId: string;
  /** This device's capability for `modelId`. */
  localCapability: number;
  /** All known peers. */
  peers: Peer[];
  /** Per-request override (X-DVAI-Offload header). */
  header: OffloadHeader;
}

export function decide(input: DecideInput): Decision {
  if (!input.config.enabled) return { kind: "local" };
  if (input.header === "never") return { kind: "local" };

  // Filter to peers that have this model loaded AND report a usable score.
  // LAN peers preferred over rendezvous peers when scores are comparable
  // (lower latency, no relay overhead) — sort key: (modelHasLoaded desc,
  // score desc, LAN-first).
  const eligible = input.peers
    .map((p): { peer: Peer; score: number; hasModel: boolean } => ({
      peer: p,
      score: p.capability[input.modelId] ?? 0,
      hasModel: p.loadedModels.includes(input.modelId),
    }))
    .filter((x) => x.score > 0)
    .sort((a, b) => {
      if (a.hasModel !== b.hasModel) return a.hasModel ? -1 : 1;
      if (a.score !== b.score) return b.score - a.score;
      // Same score, same load state: prefer mDNS over rendezvous over static.
      const order: Record<Peer["via"], number> = { mdns: 0, static: 1, custom: 2, rendezvous: 3 };
      return order[a.peer.via] - order[b.peer.via];
    });

  const bestPeer = eligible[0]?.peer;
  const bestScore = eligible[0]?.score ?? 0;
  const threshold = input.config.minLocalCapability;

  if (input.header === "require") {
    if (bestPeer && bestScore >= threshold) {
      return { kind: "offload", peer: bestPeer };
    }
    return {
      kind: "no_capable_device",
      checked: buildCheckedList(input),
      localCapability: input.localCapability,
      required: threshold,
    };
  }

  // Default: "prefer".
  if (input.localCapability >= threshold) {
    return { kind: "local" };
  }
  if (bestPeer && bestScore > input.localCapability) {
    return { kind: "offload", peer: bestPeer };
  }
  // Local is below threshold but no better peer.
  if (input.localCapability > 0) {
    return { kind: "local" };  // best we have
  }
  return {
    kind: "no_capable_device",
    checked: buildCheckedList(input),
    localCapability: input.localCapability,
    required: threshold,
  };
}

function buildCheckedList(input: DecideInput): PeerCheckResult[] {
  const list: PeerCheckResult[] = [
    {
      deviceId: "self",
      capabilityScore: input.localCapability,
      reason:
        input.localCapability < input.config.minLocalCapability
          ? "below threshold"
          : "no eligible peer found",
    },
  ];
  for (const peer of input.peers) {
    const score = peer.capability[input.modelId] ?? 0;
    list.push({
      deviceId: peer.deviceId,
      deviceName: peer.deviceName,
      capabilityScore: score,
      reason: score === 0 ? "model not advertised" : score < input.config.minLocalCapability ? "below threshold" : "checked",
    });
  }
  return list;
}
