/**
 * X25519 ephemeral key generation + shared-secret derivation.
 *
 * Both pairing devices generate an ephemeral X25519 keypair, exchange
 * public keys via the rendezvous server, and derive an identical
 * shared secret independently. The server only relays the public
 * keys — it cannot derive the secret.
 *
 * Implementation note: WebCrypto's `subtle.deriveKey` doesn't support
 * X25519 in all runtimes yet (Node has it as of 22; Safari is still
 * catching up). We use `@noble/curves/ed25519.js` (which exports x25519)
 * because it's small (~5 KB), audited, and works in every JS runtime
 * we support without a native dep.
 *
 * @noble/curves v2 note: the export path now requires the `.js` suffix
 * (v1's extensionless `@noble/curves/ed25519` was dropped from the
 * package `exports` map), and `utils.randomPrivateKey()` was renamed to
 * `utils.randomSecretKey()`. `getPublicKey` / `getSharedSecret` are
 * unchanged.
 */

import { x25519 } from "@noble/curves/ed25519.js";

export interface KeyPair {
  publicKey: Uint8Array;
  secretKey: Uint8Array;
}

/** Generate a fresh ephemeral X25519 keypair. */
export function generateEphemeralKeyPair(): KeyPair {
  const secretKey = x25519.utils.randomSecretKey();
  const publicKey = x25519.getPublicKey(secretKey);
  return { publicKey, secretKey };
}

/** Derive the 32-byte shared secret. Inputs are raw byte arrays. */
export function deriveSharedSecret(
  ourSecretKey: Uint8Array,
  theirPublicKey: Uint8Array,
): Uint8Array {
  return x25519.getSharedSecret(ourSecretKey, theirPublicKey);
}

/** Encode bytes as URL-safe base64 (no padding). */
export function encodeBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  const b64 =
    typeof btoa !== "undefined"
      ? btoa(binary)
      : Buffer.from(binary, "binary").toString("base64");
  return b64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Decode URL-safe base64 → bytes. Throws on invalid input. */
export function decodeBase64Url(s: string): Uint8Array {
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
