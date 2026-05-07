import { describe, it, expect, beforeEach } from "vitest";
import { StaticDiscovery, CompositeDiscovery, type Peer, type DiscoveryEvent } from "../discovery/index.js";

const peerA = (overrides: Partial<Peer> = {}): Peer => ({
  deviceId: "device-A",
  deviceName: "Device A",
  dvaiVersion: "3.0.0",
  baseUrl: "http://192.168.1.10:38883/v1",
  loadedModels: ["Llama-3.2-1B"],
  capability: { "Llama-3.2-1B": 25 },
  via: "static",
  secure: false,
  lastSeenAt: 0,
  ...overrides,
});

const peerB = (overrides: Partial<Peer> = {}): Peer => ({
  deviceId: "device-B",
  deviceName: "Device B",
  dvaiVersion: "3.0.0",
  baseUrl: "http://192.168.1.11:38883/v1",
  loadedModels: ["Gemma-2-2B"],
  capability: { "Gemma-2-2B": 50 },
  via: "static",
  secure: false,
  lastSeenAt: 0,
  ...overrides,
});

describe("StaticDiscovery", () => {
  it("emits peer-up for each peer on start, peer-down on stop", async () => {
    const events: DiscoveryEvent[] = [];
    const sd = new StaticDiscovery([peerA(), peerB()]);
    sd.subscribe((e) => events.push(e));

    expect(sd.peers().length).toBe(0);  // not started yet

    await sd.start();
    expect(events.filter((e) => e.type === "peer-up").length).toBe(2);
    expect(sd.peers().length).toBe(2);

    await sd.stop();
    expect(events.filter((e) => e.type === "peer-down").length).toBe(2);
    expect(sd.peers().length).toBe(0);
  });

  it("normalizes via:'static' even if the input has via:'mdns'", async () => {
    const sd = new StaticDiscovery([peerA({ via: "mdns" })]);
    await sd.start();
    expect(sd.peers()[0].via).toBe("static");
  });

  it("subscribe returns an unsubscribe function", async () => {
    const sd = new StaticDiscovery([peerA()]);
    let count = 0;
    const unsub = sd.subscribe(() => count++);
    await sd.start();
    expect(count).toBe(1);
    unsub();
    await sd.stop();
    // Already 1; stop() emits but our listener is unsubscribed.
    expect(count).toBe(1);
  });
});

describe("CompositeDiscovery", () => {
  it("merges peers from multiple sources by deviceId, keeps freshest lastSeenAt", async () => {
    const sourceA = new StaticDiscovery([peerA({ lastSeenAt: 1000 })]);
    const sourceB = new StaticDiscovery([
      peerA({ lastSeenAt: 2000, deviceName: "Device A (newer)" }),
    ]);
    const composite = new CompositeDiscovery([sourceA, sourceB]);
    await composite.start();
    const peers = composite.peers();
    expect(peers.length).toBe(1);
    expect(peers[0].deviceName).toBe("Device A (newer)");
    expect(peers[0].lastSeenAt).toBe(2000);
    await composite.stop();
  });

  it("forwards events from all sources", async () => {
    const events: DiscoveryEvent[] = [];
    const sourceA = new StaticDiscovery([peerA()]);
    const sourceB = new StaticDiscovery([peerB()]);
    const composite = new CompositeDiscovery([sourceA, sourceB]);
    composite.subscribe((e) => events.push(e));
    await composite.start();
    expect(events.filter((e) => e.type === "peer-up").length).toBe(2);
    await composite.stop();
  });

  it("returns empty peer list when not started", () => {
    const sourceA = new StaticDiscovery([peerA()]);
    const composite = new CompositeDiscovery([sourceA]);
    expect(composite.peers().length).toBe(0);
  });
});
