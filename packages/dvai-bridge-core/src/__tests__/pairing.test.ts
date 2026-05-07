import { describe, it, expect, beforeEach } from "vitest";
import {
  generatePairingKey,
  generateNonce,
  signHmac,
  verifyHmac,
  composeSignedMessage,
  InMemoryPairingStore,
  PairingPolicy,
} from "../pairing/index.js";

describe("pairing — handshake crypto", () => {
  it("generatePairingKey returns a 256-bit base64-url string", () => {
    const k = generatePairingKey();
    expect(k).toMatch(/^[A-Za-z0-9_-]+$/);
    // 32 bytes → ~43 chars in base64-url (no padding)
    expect(k.length).toBeGreaterThanOrEqual(42);
  });

  it("generateNonce returns a 128-bit base64-url string", () => {
    const n = generateNonce();
    expect(n).toMatch(/^[A-Za-z0-9_-]+$/);
    expect(n.length).toBeGreaterThanOrEqual(20);
  });

  it("signHmac + verifyHmac round-trip", async () => {
    const key = generatePairingKey();
    const sig = await signHmac(key, "hello");
    expect(await verifyHmac(key, "hello", sig)).toBe(true);
  });

  it("verifyHmac rejects a signature from a different key", async () => {
    const k1 = generatePairingKey();
    const k2 = generatePairingKey();
    const sig = await signHmac(k1, "hello");
    expect(await verifyHmac(k2, "hello", sig)).toBe(false);
  });

  it("verifyHmac rejects a signature for a different message", async () => {
    const key = generatePairingKey();
    const sig = await signHmac(key, "hello");
    expect(await verifyHmac(key, "world", sig)).toBe(false);
  });

  it("composeSignedMessage is deterministic", async () => {
    const a = await composeSignedMessage("nonce-1", "POST", "/v1/chat/completions", '{"x":1}');
    const b = await composeSignedMessage("nonce-1", "post", "/v1/chat/completions", '{"x":1}');
    // Method case-insensitive in the canonical message.
    expect(a).toBe(b);
  });

  it("composeSignedMessage uses zeros for missing body", async () => {
    const m = await composeSignedMessage("nonce-1", "GET", "/v1/dvai/health", undefined);
    // Last line is the body hash, all-zeros for no body.
    expect(m.split("\n").at(-1)).toBe("0".repeat(64));
  });
});

describe("pairing — PairingPolicy", () => {
  let store: InMemoryPairingStore;
  beforeEach(() => {
    store = new InMemoryPairingStore();
  });

  it("denies a new pairing when no callback is supplied", async () => {
    const policy = new PairingPolicy({ store });
    await expect(
      policy.approveOrFetch({ peerDeviceId: "dev-A", peerDeviceName: "A", via: "lan-handshake" }),
    ).rejects.toThrow(/denied/i);
  });

  it("accepts a new pairing when callback returns true", async () => {
    const policy = new PairingPolicy({
      store,
      onPairingRequest: async () => true,
    });
    const p = await policy.approveOrFetch({
      peerDeviceId: "dev-B",
      peerDeviceName: "B",
      via: "lan-handshake",
    });
    expect(p.peerDeviceId).toBe("dev-B");
    expect(p.pairingKey).toMatch(/^[A-Za-z0-9_-]+$/);
    expect(p.via).toBe("lan-handshake");
  });

  it("returns the existing pairing on a second call (no UI prompt)", async () => {
    let prompts = 0;
    const policy = new PairingPolicy({
      store,
      onPairingRequest: async () => {
        prompts++;
        return true;
      },
    });
    const first = await policy.approveOrFetch({
      peerDeviceId: "dev-C",
      peerDeviceName: "C",
      via: "lan-handshake",
    });
    const second = await policy.approveOrFetch({
      peerDeviceId: "dev-C",
      peerDeviceName: "C",
      via: "lan-handshake",
    });
    expect(prompts).toBe(1);
    expect(second.pairingKey).toBe(first.pairingKey);
  });

  it("expires a pairing past the TTL", async () => {
    const policy = new PairingPolicy({ store, expireAfterDays: 0.0000001 });  // microsecond TTL
    await store.set({
      peerDeviceId: "dev-D",
      peerDeviceName: "D",
      pairingKey: "fake",
      pairedAt: Date.now() - 1_000_000,
      lastUsedAt: Date.now() - 1_000_000,
      via: "lan-handshake",
    });
    const got = await policy.getActive("dev-D");
    expect(got).toBeUndefined();
  });

  it("revoke removes the pairing", async () => {
    const policy = new PairingPolicy({ store, onPairingRequest: async () => true });
    await policy.approveOrFetch({ peerDeviceId: "dev-E", peerDeviceName: "E", via: "lan-handshake" });
    await policy.revoke("dev-E");
    expect(await policy.getActive("dev-E")).toBeUndefined();
  });
});
