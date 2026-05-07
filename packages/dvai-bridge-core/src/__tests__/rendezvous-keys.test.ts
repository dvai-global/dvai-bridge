import { describe, it, expect } from "vitest";
import {
  decodeBase64Url,
  deriveSharedSecret,
  encodeBase64Url,
  generateEphemeralKeyPair,
} from "../rendezvous/keys.js";
import { decodeQrPayload } from "../rendezvous/client.js";

describe("rendezvous — keys", () => {
  it("generateEphemeralKeyPair produces 32-byte pub + secret", () => {
    const kp = generateEphemeralKeyPair();
    expect(kp.publicKey).toHaveLength(32);
    expect(kp.secretKey).toHaveLength(32);
  });

  it("two parties derive the same shared secret", () => {
    const a = generateEphemeralKeyPair();
    const b = generateEphemeralKeyPair();
    const s1 = deriveSharedSecret(a.secretKey, b.publicKey);
    const s2 = deriveSharedSecret(b.secretKey, a.publicKey);
    expect(s1).toEqual(s2);
    expect(s1).toHaveLength(32);
  });

  it("base64url round-trip preserves bytes", () => {
    const bytes = new Uint8Array([0, 1, 2, 3, 250, 251, 252, 253, 254, 255]);
    const encoded = encodeBase64Url(bytes);
    expect(encoded).not.toContain("+");
    expect(encoded).not.toContain("/");
    expect(encoded).not.toContain("=");
    const decoded = decodeBase64Url(encoded);
    expect(decoded).toEqual(bytes);
  });
});

describe("rendezvous — QR payload", () => {
  it("decodeQrPayload round-trips a valid v1 payload", () => {
    const payload = {
      v: 1 as const,
      rendezvousUrl: "wss://r.example.com",
      sessionId: "sess-123",
      sourceEphemeralPubKey: "AAAA",
      sourceDeviceId: "dev-A",
      sourceDeviceName: "Device A",
      expiresAt: Date.now() + 60_000,
    };
    const encoded = encodeBase64Url(
      new TextEncoder().encode(JSON.stringify(payload)),
    );
    const decoded = decodeQrPayload(encoded);
    expect(decoded).toEqual(payload);
  });

  it("rejects non-v1 payloads", () => {
    const bad = encodeBase64Url(
      new TextEncoder().encode(JSON.stringify({ v: 999 })),
    );
    expect(() => decodeQrPayload(bad)).toThrow(/version/i);
  });

  it("rejects payloads missing required fields", () => {
    const bad = encodeBase64Url(
      new TextEncoder().encode(JSON.stringify({ v: 1 })),
    );
    expect(() => decodeQrPayload(bad)).toThrow(/missing required/i);
  });
});
