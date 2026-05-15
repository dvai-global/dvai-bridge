#!/usr/bin/env node
/**
 * Generates a fresh ES256 (ECDSA P-256) keypair for DVAI-Bridge license
 * signing. Run ONCE when you're setting up your license infrastructure;
 * commit the public key constant into the SDK, keep the private key
 * stored in your secrets manager (1Password, AWS Secrets Manager, etc.)
 * and use it only inside your license-generator service.
 *
 * Usage:
 *   node scripts/license/generate-keypair.mjs [kid]
 *
 *   - `kid` (optional): the key identifier embedded in the JWT header
 *     and in the public key constant name. Defaults to today's date in
 *     YYYY-MM form, e.g. `2026-05`. Calendar-driven rotation is the
 *     intended pattern (issue new key annually, retire old after the
 *     longest issued license expires).
 *
 * Self-contained: uses Node's built-in `node:crypto` only. No `pnpm
 * install` required before running; works on Node 18+.
 *
 * Output (to stdout — never written to disk):
 *
 *   1. PUBLIC key as JWK → paste into
 *      packages/dvai-bridge-core/src/license/publicKeys.ts (and the
 *      equivalent native-SDK files; see comment block below for paths)
 *
 *   2. PRIVATE key as JWK → store ONLY in your secrets manager. Your
 *      license-generator service loads it from there at signing time.
 *
 *   3. A sample signed JWT → drop into a `dvai-license.jwt` file to
 *      sanity-check your SDK's validator before issuing real licenses.
 *
 * SECURITY:
 *   - The private key gives the holder permanent ability to issue
 *     valid licenses for your product. Treat it like an SSH key.
 *   - Rotate by generating a new keypair with a new `kid`, shipping
 *     the new public key in a fresh SDK release, and continuing to
 *     ship the old public key in `publicKeys.ts` for a transition
 *     window (12+ months) so previously-issued licenses keep verifying.
 *   - Never log the private key. This script intentionally avoids
 *     writing files; copy-paste from terminal into your secrets store.
 */
import {
  generateKeyPairSync,
  createSign,
  randomUUID,
} from "node:crypto";

const kid = process.argv[2] ?? new Date().toISOString().slice(0, 7); // "2026-05"

console.error("Generating ES256 keypair…");

const { publicKey, privateKey } = generateKeyPairSync("ec", {
  namedCurve: "P-256",
});

// Node's JWK export produces standard JWK shape (kty, crv, x, y, d).
// We add alg/use/kid metadata so downstream tools have everything.
const publicJwk = publicKey.export({ format: "jwk" });
const privateJwk = privateKey.export({ format: "jwk" });
publicJwk.alg = "ES256";
publicJwk.use = "sig";
publicJwk.kid = kid;
privateJwk.alg = "ES256";
privateJwk.use = "sig";
privateJwk.kid = kid;

// Build a sample license JWT so the operator can round-trip the
// validator end-to-end before issuing real licenses.
const now = Math.floor(Date.now() / 1000);
const sampleJwt = signEs256Jwt(privateKey, {
  header: { alg: "ES256", typ: "JWT", kid },
  payload: {
    iss: "DVAI-Bridge",
    sub: randomUUID(),
    aud: ["localhost", "*.example.com", "com.example.app"],
    tier: "trial",
    licensee: "Sample Co — example, not a real license",
    platforms: [
      "web",
      "node",
      "ios",
      "android",
      "dotnet",
      "flutter",
      "react-native",
      "capacitor",
    ],
    iat: now,
    exp: now + 90 * 24 * 60 * 60, // 90 days
  },
});

console.log("");
console.log("=".repeat(72));
console.log(`  Generated ES256 keypair (kid="${kid}")`);
console.log("=".repeat(72));
console.log("");
console.log("--- 1. PUBLIC KEY (commit into every SDK) -------------------------------");
console.log("");
console.log("Paste an entry like this into the public-key registries:");
console.log("");
console.log(`  "${kid}": ${stringify(publicJwk).replace(/\n/g, "\n  ")},`);
console.log("");
console.log("Files to update (one entry per file — keep the placeholder entry");
console.log("only if you want test/sample tokens to keep validating):");
console.log("  - packages/dvai-bridge-core/src/license/publicKeys.ts");
console.log("  - packages/dvai-bridge-ios/ios/Sources/DVAIBridge/License/PublicKeys.swift");
console.log("  - packages/dvai-bridge-android/android/src/main/java/co/deepvoiceai/bridge/license/PublicKeys.kt");
console.log("  - packages/dvai-bridge-dotnet/src/DVAIBridge/License/PublicKeys.cs");
console.log("  - packages/dvai-bridge-flutter/lib/src/license/public_keys.dart");
console.log("");
console.log("--- 2. PRIVATE KEY (store in your secrets manager) -----------------------");
console.log("");
console.log("Store this in 1Password / AWS Secrets Manager / Vault — NEVER commit.");
console.log("Your license-generator service reads it from there at signing time.");
console.log("");
console.log(JSON.stringify(privateJwk));
console.log("");
console.log("--- 3. Sample license JWT for sanity-checking your SDK validator --------");
console.log("");
console.log(sampleJwt);
console.log("");
console.log("Drop the above token into a file named `dvai-license.jwt` at your");
console.log("SDK's default discovery location (or set DVAI_LICENSE_TOKEN env var),");
console.log("run your app, and confirm `licenseStatus.kind === \"trial\"`. Then");
console.log("revoke this sample by re-running the keypair generation, and issue");
console.log("real licenses against the new key.");
console.log("");
console.log("=".repeat(72));

/* -------------------------------------------------------------------------- */
/* Helpers                                                                    */
/* -------------------------------------------------------------------------- */

/**
 * Sign a JWT using ES256 with a KeyObject private key. JWT/JOSE
 * requires ECDSA signatures in IEEE P1363 (raw r||s concat) format —
 * Node's `crypto.createSign().sign()` defaults to DER, so we pass
 * `{ dsaEncoding: "ieee-p1363" }` explicitly. Without it the resulting
 * signature is malformed for JOSE verifiers and every validator
 * silently rejects the token.
 */
function signEs256Jwt(privateKey, { header, payload }) {
  const headerB64 = base64Url(JSON.stringify(header));
  const payloadB64 = base64Url(JSON.stringify(payload));
  const signingInput = `${headerB64}.${payloadB64}`;
  const signer = createSign("SHA256");
  signer.update(signingInput);
  signer.end();
  const signatureRaw = signer.sign({
    key: privateKey,
    dsaEncoding: "ieee-p1363",
  });
  const signatureB64 = base64UrlBuffer(signatureRaw);
  return `${signingInput}.${signatureB64}`;
}

function base64Url(str) {
  return base64UrlBuffer(Buffer.from(str, "utf8"));
}

function base64UrlBuffer(buf) {
  return buf
    .toString("base64")
    .replace(/=+$/u, "")
    .replace(/\+/gu, "-")
    .replace(/\//gu, "_");
}

/** Stable JSON.stringify for the public-key paste — keeps the
 *  output multi-line so it's readable when pasted into the SDK
 *  source. */
function stringify(obj) {
  return JSON.stringify(obj, null, 2);
}
