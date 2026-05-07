/**
 * Static-list discovery source. Apps that already know about peer
 * devices (e.g. a corporate device registry, hard-coded testbed
 * peers, persistent pairings restored across restart) supply a static
 * Peer[] at config time.
 *
 * The list is treated as authoritative — we don't health-check the
 * URLs here. The offload decider runs reachability checks before
 * actually using a peer.
 */

import type { DiscoveryEvent, IDiscovery, Peer } from "./types.js";

export class StaticDiscovery implements IDiscovery {
  private readonly listeners = new Set<(e: DiscoveryEvent) => void>();
  private readonly peerList: Peer[];
  private started = false;

  constructor(peers: Peer[]) {
    // Normalize lastSeenAt to "now" if not supplied (treat 0 as
    // "no value, use now"). Preserve explicit non-zero values so
    // tests + custom merges that care about ordering can pass them.
    const now = Date.now();
    this.peerList = peers.map((p) => ({
      ...p,
      lastSeenAt: p.lastSeenAt && p.lastSeenAt > 0 ? p.lastSeenAt : now,
      via: "static",
    }));
  }

  async start(): Promise<void> {
    if (this.started) return;
    this.started = true;
    // Emit peer-up for each immediately so consumers see them on
    // first poll.
    for (const peer of this.peerList) {
      this.emit({ type: "peer-up", peer });
    }
  }

  async stop(): Promise<void> {
    this.started = false;
    for (const peer of this.peerList) {
      this.emit({ type: "peer-down", deviceId: peer.deviceId });
    }
  }

  peers(): Peer[] {
    return this.started ? [...this.peerList] : [];
  }

  subscribe(listener: (e: DiscoveryEvent) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private emit(e: DiscoveryEvent): void {
    for (const listener of this.listeners) {
      try {
        listener(e);
      } catch (err) {
        // Don't let one buggy listener break the others.
        console.error("[DVAI/discovery] listener threw:", err);
      }
    }
  }
}
