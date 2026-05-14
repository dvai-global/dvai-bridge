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
 *     and in the public key constant name. Defaults to today's date,
 *     e.g. `2026-05`. Use `YYYY-MM` style so rotation is calendar-driven.
 *
 * Outputs to stdout (NEVER committed) — paste each block into the
 * indicated destination:
 *
 *   1. The PUBLIC key as a JWK → drop into
 *      packages/dvai-bridge-core/src/license/publicKeys.ts
 *      (and the equivalent file in each native SDK)
 *
 *   2. The PRIVATE key as a JWK → store ONLY in your secrets manager.
 *      Your license-generator service loads it from there.
 *
 *   3. A sample signed JWT → for sanity-checking your SDK's validator.
 *
 * SECURITY:
 *   - The private key gives the holder permanent ability to issue
 *     valid licenses for your product. Treat it like an SSH key.
 *   - Rotate by generating a new keypair with a new kid, shipping the
 *     new public key in a fresh SDK release, and continuing to ship
 *     the old public key in `publicKeys.ts` for a transition window
 *     (12+ months) so existing licenses keep verifying.
 *   - Never log the private key. This script intentionally avoids
 *     writing files; copy-paste from terminal into your secrets store.
 */
import { generateKeyPair, exportJWK } from "jose";
import { SignJWT } from "jose";

const kid = process.argv[2] ?? new Date().toISOString().slice(0, 7); // "2026-05"

console.error("Generating ES256 keypair...");
const { publicKey, privateKey } = await generateKeyPair("ES256", {
  extractable: true,
});

const publicJwk = await exportJWK(publicKey);
const privateJwk = await exportJWK(privateKey);

// Add the algorithm + use + kid metadata so downstream tools don't guess.
publicJwk.alg = "ES256";
publicJwk.use = "sig";
publicJwk.kid = kid;
privateJwk.alg = "ES256";
privateJwk.use = "sig";
privateJwk.kid = kid;

console.log("");
console.log("=".repeat(72));
console.log(`  Generated ES256 keypair (kid="${kid}")`);
console.log("=".repeat(72));
console.log("");
console.log("--- 1. PUBLIC KEY (commit into the SDK) ----------------------------------");
console.log("");
console.log("Paste this into:");
console.log("  packages/dvai-bridge-core/src/license/publicKeys.ts");
console.log("");
console.log("Add as an entry in DVAI_PUBLIC_KEYS:");
console.log(`  "${kid}": ${JSON.stringify(publicJwk, null, 2).replace(/\n/g, "\n  ")},`);
console.log("");
console.log("--- 2. PRIVATE KEY (store in your secrets manager) -----------------------");
console.log("");
console.log("Store this in 1Password / AWS Secrets Manager / etc. — NEVER commit.");
console.log("Your license-generator service loads it from there at signing time.");
console.log("");
console.log(JSON.stringify(privateJwk));
console.log("");
console.log("--- 3. Sample license JWT for sanity-checking your SDK validator --------");
console.log("");

// Sign a sample license so the user can verify their SDK setup end-to-end.
const sampleJwt = await new SignJWT({
  tier: "commercial",
  licensee: "Sample Co — example, not a real license",
  platforms: ["web", "ios", "android", "dotnet", "flutter", "react-native", "capacitor"],
})
  .setProtectedHeader({ alg: "ES256", typ: "JWT", kid })
  .setIssuer("DVAI-Bridge")
  .setSubject("sample-license-do-not-use")
  .setAudience(["localhost", "*.example.com", "com.example.app"])
  .setIssuedAt()
  .setExpirationTime("90d")
  .sign(privateKey);

console.log(sampleJwt);
console.log("");
console.log("Drop the above string into a file (e.g. dvai-license.jwt) at the SDK's");
console.log("default discovery location, run your app, and confirm the SDK reports");
console.log("`tier: \"commercial\"`. Then revoke this sample and issue real licenses.");
console.log("");
console.log("=".repeat(72));
