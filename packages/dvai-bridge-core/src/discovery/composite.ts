/**
 * Composite discovery — combines mDNS + static + rendezvous-paired
 * peers into a single unified peer stream. The offload decider only
 * talks to this layer; it doesn't know which source produced a peer.
 *
 * Per-source peers are deduplicated by `deviceId` — the most-recent
 * `lastSeenAt` wins, with mDNS preferred over static when both
 * exist (same device, but mDNS gives us a fresher TXT).
 */

import type { DiscoveryEvent, IDiscovery, Peer } from "./types.js";

export class CompositeDiscovery implements IDiscovery {
  private readonly listeners = new Set<(e: DiscoveryEvent) => void>();
  private readonly subscriptions: Array<() => void> = [];
  private started = false;

  constructor(private readonly sources: IDiscovery[]) {}

  async start(): Promise<void> {
    if (this.started) return;
    this.started = true;
    for (const source of this.sources) {
      const unsub = source.subscribe((e) => this.onEvent(e));
      this.subscriptions.push(unsub);
      await source.start();
    }
  }

  async stop(): Promise<void> {
    if (!this.started) return;
    this.started = false;
    for (const unsub of this.subscriptions) unsub();
    this.subscriptions.length = 0;
    for (const source of this.sources) {
      await source.stop();
    }
  }

  peers(): Peer[] {
    const merged = new Map<string, Peer>();
    for (const source of this.sources) {
      for (const peer of source.peers()) {
        const existing = merged.get(peer.deviceId);
        if (!existing || peer.lastSeenAt > existing.lastSeenAt) {
          merged.set(peer.deviceId, peer);
        }
      }
    }
    return Array.from(merged.values());
  }

  subscribe(listener: (e: DiscoveryEvent) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private onEvent(e: DiscoveryEvent): void {
    // Forward all events. Consumers handle duplicates via the merged
    // peer set rather than us trying to dedupe events here (an event
    // for one source might still be informative — e.g. the rendezvous
    // peer dropped but the LAN peer is still up).
    for (const listener of this.listeners) {
      try {
        listener(e);
      } catch (err) {
        console.error("[DVAI/discovery] listener threw:", err);
      }
    }
  }
}

/** Factory: pick the right mDNS adapter for the runtime. */
export async function createMdnsDiscovery(opts: {
  selfDeviceId: string;
  advertise?: import("./mdns-node.js").AdvertisedTxt;
}): Promise<IDiscovery> {
  if (
    typeof globalThis.process !== "undefined" &&
    globalThis.process.versions?.node
  ) {
    const { NodeMdnsDiscovery } = await import("./mdns-node.js");
    return new NodeMdnsDiscovery(opts);
  }
  const { BrowserMdnsDiscovery } = await import("./mdns-browser.js");
  return new BrowserMdnsDiscovery();
}
