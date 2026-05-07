import { describe, it, expect } from "vitest";
import { decide, parseOffloadHeader, buildNoCapableDeviceResponse } from "../offload/index.js";
import type { OffloadConfig } from "../offload/index.js";
import type { Peer } from "../discovery/index.js";

const baseConfig: OffloadConfig = {
  enabled: true,
  discoverLAN: true,
  minLocalCapability: 10,
};

const fastPeer: Peer = {
  deviceId: "peer-fast",
  deviceName: "Mac Studio",
  dvaiVersion: "3.0.0",
  baseUrl: "http://192.168.1.10:38883/v1",
  loadedModels: ["model-A"],
  capability: { "model-A": 50 },
  via: "mdns",
  secure: false,
  lastSeenAt: Date.now(),
};

const slowPeer: Peer = {
  deviceId: "peer-slow",
  deviceName: "Old laptop",
  dvaiVersion: "3.0.0",
  baseUrl: "http://192.168.1.20:38883/v1",
  loadedModels: ["model-A"],
  capability: { "model-A": 5 },
  via: "mdns",
  secure: false,
  lastSeenAt: Date.now(),
};

describe("offload — decide()", () => {
  it("offload disabled → local", () => {
    const d = decide({
      config: { ...baseConfig, enabled: false },
      modelId: "model-A",
      localCapability: 2,
      peers: [fastPeer],
      header: "prefer",
    });
    expect(d.kind).toBe("local");
  });

  it("X-DVAI-Offload: never → local even with fast peer", () => {
    const d = decide({
      config: baseConfig,
      modelId: "model-A",
      localCapability: 2,
      peers: [fastPeer],
      header: "never",
    });
    expect(d.kind).toBe("local");
  });

  it("prefer + slow local + fast peer → offload", () => {
    const d = decide({
      config: baseConfig,
      modelId: "model-A",
      localCapability: 2,
      peers: [fastPeer],
      header: "prefer",
    });
    expect(d.kind).toBe("offload");
    if (d.kind === "offload") expect(d.peer.deviceId).toBe("peer-fast");
  });

  it("prefer + fast local → local (no offload)", () => {
    const d = decide({
      config: baseConfig,
      modelId: "model-A",
      localCapability: 25,
      peers: [fastPeer],
      header: "prefer",
    });
    expect(d.kind).toBe("local");
  });

  it("prefer + slow local + only-slow peer → local fallback", () => {
    const d = decide({
      config: baseConfig,
      modelId: "model-A",
      localCapability: 4,
      peers: [slowPeer],  // 5 tok/s, below 10 threshold
      header: "prefer",
    });
    // Local 4 vs peer 5: peer is better, so we offload.
    expect(d.kind).toBe("offload");
  });

  it("prefer + slow local + no peer → local fallback (best we have)", () => {
    const d = decide({
      config: baseConfig,
      modelId: "model-A",
      localCapability: 4,
      peers: [],
      header: "prefer",
    });
    expect(d.kind).toBe("local");
  });

  it("prefer + zero local + no peer → no_capable_device", () => {
    const d = decide({
      config: baseConfig,
      modelId: "model-A",
      localCapability: 0,
      peers: [],
      header: "prefer",
    });
    expect(d.kind).toBe("no_capable_device");
  });

  it("require + below-threshold peer → no_capable_device", () => {
    const d = decide({
      config: baseConfig,
      modelId: "model-A",
      localCapability: 4,
      peers: [slowPeer],
      header: "require",
    });
    expect(d.kind).toBe("no_capable_device");
  });

  it("require + fast peer → offload", () => {
    const d = decide({
      config: baseConfig,
      modelId: "model-A",
      localCapability: 4,
      peers: [fastPeer],
      header: "require",
    });
    expect(d.kind).toBe("offload");
  });

  it("sorts peers by score, prefers LAN over rendezvous at same score", () => {
    const lanPeer: Peer = { ...fastPeer, deviceId: "lan", via: "mdns", capability: { "model-A": 30 } };
    const rdvPeer: Peer = { ...fastPeer, deviceId: "rdv", via: "rendezvous", capability: { "model-A": 30 } };
    const d = decide({
      config: baseConfig,
      modelId: "model-A",
      localCapability: 2,
      peers: [rdvPeer, lanPeer],  // intentionally rdv first
      header: "prefer",
    });
    expect(d.kind).toBe("offload");
    if (d.kind === "offload") expect(d.peer.deviceId).toBe("lan");
  });

  it("filters out peers that don't have the model loaded", () => {
    const peerWithoutModel: Peer = {
      ...fastPeer,
      deviceId: "peer-other-model",
      loadedModels: ["different-model"],
      capability: { "different-model": 100 },
    };
    const d = decide({
      config: baseConfig,
      modelId: "model-A",
      localCapability: 0,  // can't run model-A locally either
      peers: [peerWithoutModel],
      header: "prefer",
    });
    expect(d.kind).toBe("no_capable_device");  // model-A nowhere reachable
  });
});

describe("offload — parseOffloadHeader", () => {
  it("defaults to prefer when missing", () => {
    expect(parseOffloadHeader({})).toBe("prefer");
  });
  it("reads from a Headers object case-insensitively", () => {
    const h = new Headers({ "X-DVAI-Offload": "REQUIRE" });
    expect(parseOffloadHeader(h)).toBe("require");
  });
  it("reads from a plain object case-insensitively", () => {
    expect(parseOffloadHeader({ "x-dvai-offload": "Never" })).toBe("never");
  });
  it("rejects unknown values, returns prefer", () => {
    expect(parseOffloadHeader({ "x-dvai-offload": "bogus" })).toBe("prefer");
  });
});

describe("offload — buildNoCapableDeviceResponse", () => {
  it("returns a 503 with retry-after + OpenAI-error-shaped body", () => {
    const r = buildNoCapableDeviceResponse(
      {
        kind: "no_capable_device",
        checked: [
          { deviceId: "self", capabilityScore: 4, reason: "below threshold" },
        ],
        localCapability: 4,
        required: 10,
      },
      { rendezvousConfigured: false, pairedRemotePeers: 0, modelId: "model-A" },
    );
    expect(r.status).toBe(503);
    expect(r.headers["Retry-After"]).toBe("30");
    expect(r.body.error.type).toBe("no_capable_device");
    expect(r.body.error.localCapability).toBe(4);
    expect(r.body.error.requiredAtLeast).toBe(10);
  });
});
