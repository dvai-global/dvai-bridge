/**
 * LAN-pairing handshake. The first time Device A wants to offload to
 * Device B over the LAN, A POSTs /v1/dvai/handshake to B with its
 * identity + a nonce. B surfaces a UI prompt to the user; on approve,
 * B generates a 256-bit pairing key and returns it. From then on, A
 * includes `X-DVAI-Pairing: HMAC-SHA256(pairingKey, body)` on every
 * offload request to B.
 */

import { encodeBase64Url } from "../rendezvous/keys.js";
import type { HandshakeRequest, HandshakeResponse } from "./types.js";

/** Generate a fresh 256-bit pairing key (base64-url encoded). */
export function generatePairingKey(): string {
  const cryptoApi = typeof globalThis.crypto !== "undefined" ? globalThis.crypto : undefined;
  if (!cryptoApi || typeof cryptoApi.getRandomValues !== "function") {
    throw new Error("[DVAI/pairing] no secure random source");
  }
  const bytes = new Uint8Array(32);
  cryptoApi.getRandomValues(bytes);
  return encodeBase64Url(bytes);
}

/** Generate a fresh nonce for a handshake request. */
export function generateNonce(): string {
  const cryptoApi = typeof globalThis.crypto !== "undefined" ? globalThis.crypto : undefined;
  if (!cryptoApi || typeof cryptoApi.getRandomValues !== "function") {
    throw new Error("[DVAI/pairing] no secure random source");
  }
  const bytes = new Uint8Array(16);
  cryptoApi.getRandomValues(bytes);
  return encodeBase64Url(bytes);
}

/**
 * HMAC-SHA256(key, message). Used to sign offload requests so the
 * peer can verify they came from a paired device.
 */
export async function signHmac(
  pairingKey: string,
  message: string,
): Promise<string> {
  const cryptoApi = globalThis.crypto;
  if (!cryptoApi?.subtle) {
    throw new Error("[DVAI/pairing] WebCrypto subtle not available");
  }
  const keyBytes = decodeBase64UrlBytes(pairingKey);
  const cryptoKey = await cryptoApi.subtle.importKey(
    "raw",
    keyBytes as ArrayBuffer,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await cryptoApi.subtle.sign(
    "HMAC",
    cryptoKey,
    new TextEncoder().encode(message) as ArrayBuffer,
  );
  return encodeBase64Url(new Uint8Array(sig));
}

/** Verify an HMAC. Returns true on match, false otherwise (constant-time-ish). */
export async function verifyHmac(
  pairingKey: string,
  message: string,
  signature: string,
): Promise<boolean> {
  const expected = await signHmac(pairingKey, message);
  return constantTimeEquals(expected, signature);
}

function constantTimeEquals(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

function decodeBase64UrlBytes(s: string): Uint8Array {
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/");
  const padded = b64 + "=".repeat((4 - (b64.length % 4)) % 4);
  const binary =
    typeof atob !== "undefined"
      ? atob(padded)
      : Buffer.from(padded, "base64").toString("binary");
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

/**
 * Compose the canonical message that gets HMAC-signed for a peer-to-peer
 * offload request. The peer recomputes the same string and verifies.
 *
 * Format: `${nonce}\n${method}\n${path}\n${bodyHash}` — bodyHash is the
 * hex-encoded SHA-256 of the request body bytes.
 */
export async function composeSignedMessage(
  nonce: string,
  method: string,
  path: string,
  body: string | undefined,
): Promise<string> {
  const bodyHash = body
    ? await sha256Hex(body)
    : "0000000000000000000000000000000000000000000000000000000000000000";
  return `${nonce}\n${method.toUpperCase()}\n${path}\n${bodyHash}`;
}

async function sha256Hex(input: string): Promise<string> {
  const cryptoApi = globalThis.crypto;
  if (!cryptoApi?.subtle) {
    throw new Error("[DVAI/pairing] WebCrypto subtle not available");
  }
  const buf = await cryptoApi.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(input) as ArrayBuffer,
  );
  return Array.from(new Uint8Array(buf))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

export type { HandshakeRequest, HandshakeResponse };
