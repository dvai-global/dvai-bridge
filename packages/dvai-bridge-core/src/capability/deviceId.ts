/**
 * Stable per-install device identifier. Generated once on first call,
 * persisted alongside the capability cache. Used for:
 *   - identifying THIS device in mDNS TXT records (LAN discovery).
 *   - identifying THIS device in rendezvous-server pairing payloads.
 *   - keying the capability cache.
 *
 * NOT a privacy hazard: the ID is per-install and per-device-storage,
 * never tied to user identity. Reinstalling the app or wiping app
 * storage produces a fresh ID — that's the right behaviour.
 */

/** Generate a 22-char URL-safe random ID. */
export function generateDeviceId(): string {
  // Pull from the platform's secure random source. WebCrypto is
  // available in browsers, Node 19+, Bun, Deno.
  const cryptoApi: Crypto | undefined =
    typeof globalThis.crypto !== "undefined" ? globalThis.crypto : undefined;

  if (!cryptoApi || typeof cryptoApi.getRandomValues !== "function") {
    throw new Error(
      "[DVAI/capability] No secure random source available. " +
        "globalThis.crypto.getRandomValues required (Node ≥19, modern browsers, Bun, Deno).",
    );
  }

  const bytes = new Uint8Array(16);
  cryptoApi.getRandomValues(bytes);
  return base64UrlEncode(bytes);
}

function base64UrlEncode(bytes: Uint8Array): string {
  // Browser + Node-compatible: convert to base64, then URL-safe.
  let binary = "";
  for (const b of bytes) {
    binary += String.fromCharCode(b);
  }
  const b64 = typeof btoa !== "undefined"
    ? btoa(binary)
    : Buffer.from(binary, "binary").toString("base64");
  return b64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
