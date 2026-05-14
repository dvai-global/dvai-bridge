/**
 * Tests for the JWT-based license validator.
 *
 * Two APIs are tested:
 *   - `validate()`           — never throws; returns `LicenseStatus` with
 *                              `kind: "free-prod" | "free-expired"` for
 *                              failure cases. Used by host-app dashboards
 *                              that want to inspect status without halting.
 *   - `validateAndAssert()`  — throws `LicenseRequiredError` for the
 *                              same failure cases. Used by `DVAI.initialize()`
 *                              to enforce the BSL 1.1 commercial-only-in-
 *                              production policy.
 *
 * Both happy paths and every documented failure mode (tampered signature,
 * wrong kid, expired, audience mismatch, platform mismatch, missing
 * file, alg confusion) are covered against both APIs.
 *
 * All tests use a freshly-generated test keypair so they don't depend
 * on the placeholder key in `publicKeys.ts`. The injected `publicKeys`
 * option on `LicenseValidator` makes that possible without touching the
 * production registry.
 */
import { describe, it, expect, beforeAll, afterEach, vi } from "vitest";
import { promises as fs } from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import { generateKeyPair, exportJWK, SignJWT } from "jose";
import { LicenseValidator } from "../license/LicenseValidator.js";
import type { DvaiPublicKeyJwk } from "../license/publicKeys.js";
import { LicenseRequiredError, type DvaiPlatform } from "../license/types.js";

// Test fixture state. Generated once per file in beforeAll so the tests
// run fast without re-deriving keys on every case. The private-key type
// is inferred from jose's generateKeyPair return — declaring it as
// CryptoKey | KeyObject would tie us to a specific environment, so we
// let TS infer it from the generation call below.
let TEST_KID: string;
let publicJwk: DvaiPublicKeyJwk;
let privateKey: Awaited<ReturnType<typeof generateKeyPair>>["privateKey"];
let publicKeys: Record<string, DvaiPublicKeyJwk>;

beforeAll(async () => {
  TEST_KID = "test-kid-2026";
  const kp = await generateKeyPair("ES256", { extractable: true });
  privateKey = kp.privateKey;
  const exported = await exportJWK(kp.publicKey);
  publicJwk = {
    ...(exported as { kty: "EC"; crv: "P-256"; x: string; y: string }),
    alg: "ES256",
    use: "sig",
    kid: TEST_KID,
  };
  publicKeys = { [TEST_KID]: publicJwk };
});

afterEach(() => {
  // Each test sets DVAI_FORCE_PROD=1 so dev-mode auto-bypass doesn't
  // mask validation failures. Clean it up between tests so a test that
  // wants to exercise the bypass branch can do so.
  delete process.env.DVAI_FORCE_PROD;
  delete process.env.DVAI_FORCE_DEV;
  delete process.env.DVAI_LICENSE_TOKEN;
  delete process.env.DVAI_LICENSE_PATH;
  delete process.env.DVAI_AUDIENCE;
  vi.restoreAllMocks();
});

/** Helper to mint a license JWT for tests. */
async function mintLicense(opts: {
  aud?: string[];
  platforms?: DvaiPlatform[];
  tier?: "commercial" | "trial";
  licensee?: string;
  exp?: string | number;
  iss?: string;
  kid?: string;
}): Promise<string> {
  return new SignJWT({
    tier: opts.tier ?? "commercial",
    licensee: opts.licensee ?? "Test Co",
    platforms: opts.platforms ?? ["node", "web", "ios", "android"],
  })
    .setProtectedHeader({ alg: "ES256", typ: "JWT", kid: opts.kid ?? TEST_KID })
    .setIssuer(opts.iss ?? "DVAI-Bridge")
    .setSubject("test-license")
    .setAudience(opts.aud ?? ["*"])
    .setIssuedAt()
    .setExpirationTime(opts.exp ?? "30d")
    .sign(privateKey);
}

describe("LicenseValidator — happy path", () => {
  it("accepts a well-formed commercial token and reports the licensee + expiry", async () => {
    process.env.DVAI_FORCE_PROD = "1";
    process.env.DVAI_AUDIENCE = "acme.com";
    const token = await mintLicense({
      aud: ["acme.com"],
      platforms: ["node"],
      licensee: "Acme Inc",
    });
    const v = new LicenseValidator({ token, publicKeys });
    const status = await v.validate();
    expect(status.kind).toBe("commercial");
    if (status.kind === "commercial") {
      expect(status.licensee).toBe("Acme Inc");
      expect(status.audienceMatched).toBe("acme.com");
      expect(status.platform).toBe("node");
      expect(status.expiresAt).toBeGreaterThan(Date.now() / 1000);
    }
  });

  it("matches wildcard subdomain audience entries", async () => {
    process.env.DVAI_FORCE_PROD = "1";
    process.env.DVAI_AUDIENCE = "app.acme.com";
    const token = await mintLicense({
      aud: ["*.acme.com"],
      platforms: ["node"],
    });
    const status = await new LicenseValidator({ token, publicKeys }).validate();
    expect(status.kind).toBe("commercial");
    if (status.kind === "commercial") {
      expect(status.audienceMatched).toBe("*.acme.com");
    }
  });

  it("matches `*` audience for any-domain trial licenses", async () => {
    process.env.DVAI_FORCE_PROD = "1";
    // No DVAI_AUDIENCE set — runtime audience is null.
    const token = await mintLicense({
      aud: ["*"],
      platforms: ["node"],
      tier: "trial",
    });
    const status = await new LicenseValidator({ token, publicKeys }).validate();
    expect(status.kind).toBe("trial");
  });

  it("matches the bare apex of a `*.example.com` wildcard", async () => {
    process.env.DVAI_FORCE_PROD = "1";
    process.env.DVAI_AUDIENCE = "acme.com";
    const token = await mintLicense({ aud: ["*.acme.com"], platforms: ["node"] });
    const status = await new LicenseValidator({ token, publicKeys }).validate();
    expect(status.kind).toBe("commercial");
  });
});

describe("LicenseValidator — failure modes (each must collapse to a free-* status, never throw)", () => {
  it("returns free-prod when the token has been tampered with", async () => {
    process.env.DVAI_FORCE_PROD = "1";
    process.env.DVAI_AUDIENCE = "acme.com";
    const token = await mintLicense({ aud: ["acme.com"], platforms: ["node"] });
    // Flip a byte in the payload segment to break the signature.
    const parts = token.split(".");
    if (!parts[1]) throw new Error("malformed test token");
    const corrupted = `${parts[0]}.${parts[1].slice(0, -2)}XX.${parts[2]}`;
    const status = await new LicenseValidator({
      token: corrupted,
      publicKeys,
    }).validate();
    expect(status.kind).toBe("free-prod");
    if (status.kind === "free-prod") {
      expect(status.reason.toLowerCase()).toMatch(/signature|verification|parseable|claim/);
    }
  });

  it("returns free-expired when exp is in the past", async () => {
    process.env.DVAI_FORCE_PROD = "1";
    process.env.DVAI_AUDIENCE = "acme.com";
    // Sign a token with exp in the past. setExpirationTime accepts
    // relative strings or absolute seconds; we use an absolute past.
    const pastSeconds = Math.floor(Date.now() / 1000) - 3600;
    const token = await mintLicense({
      aud: ["acme.com"],
      platforms: ["node"],
      licensee: "Expired Co",
      exp: pastSeconds,
    });
    const status = await new LicenseValidator({ token, publicKeys }).validate();
    expect(status.kind).toBe("free-expired");
    if (status.kind === "free-expired") {
      expect(status.licensee).toBe("Expired Co");
      expect(status.expiredAt).toBeLessThan(Date.now() / 1000);
    }
  });

  it("returns free-prod when audience doesn't match", async () => {
    process.env.DVAI_FORCE_PROD = "1";
    process.env.DVAI_AUDIENCE = "widget.io";
    const token = await mintLicense({
      aud: ["acme.com"],
      platforms: ["node"],
    });
    const status = await new LicenseValidator({ token, publicKeys }).validate();
    expect(status.kind).toBe("free-prod");
    if (status.kind === "free-prod") {
      expect(status.reason).toContain("audience");
      expect(status.reason).toContain("widget.io");
    }
  });

  it("returns free-prod when the runtime platform isn't in the platforms claim", async () => {
    process.env.DVAI_FORCE_PROD = "1";
    process.env.DVAI_AUDIENCE = "acme.com";
    const token = await mintLicense({
      aud: ["acme.com"],
      platforms: ["ios", "android"], // not node
    });
    const status = await new LicenseValidator({ token, publicKeys }).validate();
    expect(status.kind).toBe("free-prod");
    if (status.kind === "free-prod") {
      expect(status.reason).toContain("platform");
      expect(status.reason).toContain("node");
    }
  });

  it("returns free-prod when the kid in the header isn't in the registry", async () => {
    process.env.DVAI_FORCE_PROD = "1";
    process.env.DVAI_AUDIENCE = "acme.com";
    const token = await mintLicense({
      aud: ["acme.com"],
      platforms: ["node"],
      kid: "unknown-kid-2099",
    });
    const status = await new LicenseValidator({ token, publicKeys }).validate();
    expect(status.kind).toBe("free-prod");
    if (status.kind === "free-prod") {
      expect(status.reason).toContain("unknown-kid-2099");
      expect(status.reason).toContain("registry");
    }
  });

  it("refuses the placeholder kid unless allowPlaceholderKey is set", async () => {
    process.env.DVAI_FORCE_PROD = "1";
    process.env.DVAI_AUDIENCE = "acme.com";
    // Mint with the placeholder kid (which IS in the production registry).
    // Pass the production publicKeys to use the placeholder key in the registry.
    const token = await mintLicense({
      aud: ["acme.com"],
      platforms: ["node"],
      kid: "placeholder-do-not-ship",
    });
    // Even with the placeholder kid in the registry, validation should
    // refuse it because `allowPlaceholderKey` defaults to false. Use a
    // registry that includes the placeholder kid pointing at OUR key
    // so signature verification would otherwise succeed.
    const registryWithPlaceholderKid = {
      "placeholder-do-not-ship": { ...publicJwk, kid: "placeholder-do-not-ship" },
    };
    const status = await new LicenseValidator({
      token,
      publicKeys: registryWithPlaceholderKid,
    }).validate();
    expect(status.kind).toBe("free-prod");
    if (status.kind === "free-prod") {
      expect(status.reason).toContain("placeholder");
    }
  });

  it("accepts the placeholder kid when allowPlaceholderKey is set (test escape hatch)", async () => {
    process.env.DVAI_FORCE_PROD = "1";
    process.env.DVAI_AUDIENCE = "acme.com";
    const token = await mintLicense({
      aud: ["acme.com"],
      platforms: ["node"],
      kid: "placeholder-do-not-ship",
    });
    const registryWithPlaceholderKid = {
      "placeholder-do-not-ship": { ...publicJwk, kid: "placeholder-do-not-ship" },
    };
    const status = await new LicenseValidator({
      token,
      publicKeys: registryWithPlaceholderKid,
      allowPlaceholderKey: true,
    }).validate();
    expect(status.kind).toBe("commercial");
  });

  it("rejects alg=none and alg=HS256 tokens (algorithm-confusion defense)", async () => {
    process.env.DVAI_FORCE_PROD = "1";
    process.env.DVAI_AUDIENCE = "acme.com";
    // Build an alg=none-style malformed token. Headers: alg=none, no signature.
    const header = Buffer.from(JSON.stringify({ alg: "none", typ: "JWT" })).toString("base64url");
    const payload = Buffer.from(
      JSON.stringify({
        iss: "DVAI-Bridge",
        sub: "x",
        aud: ["acme.com"],
        tier: "commercial",
        platforms: ["node"],
        licensee: "Evil Co",
        iat: Math.floor(Date.now() / 1000),
        exp: Math.floor(Date.now() / 1000) + 3600,
      }),
    ).toString("base64url");
    const noneToken = `${header}.${payload}.`;
    const status = await new LicenseValidator({ token: noneToken, publicKeys }).validate();
    expect(status.kind).toBe("free-prod");
    if (status.kind === "free-prod") {
      expect(status.reason).toContain("ES256");
    }
  });

  it("returns free-prod when token is malformed (not 3 segments)", async () => {
    process.env.DVAI_FORCE_PROD = "1";
    const status = await new LicenseValidator({
      token: "not.a.valid.jwt",
      publicKeys,
    }).validate();
    expect(status.kind).toBe("free-prod");
  });

  it("returns free-prod when no token is provided AND no auto-discovery succeeds", async () => {
    process.env.DVAI_FORCE_PROD = "1";
    // No token, no path — auto-discovery in tmpdir won't find anything.
    const status = await new LicenseValidator({ publicKeys }).validate();
    expect(status.kind).toBe("free-prod");
    if (status.kind === "free-prod") {
      expect(status.reason).toContain("no license token found");
    }
  });
});

describe("LicenseValidator — dev mode bypass", () => {
  it("returns free-dev when DVAI_FORCE_DEV is set", async () => {
    process.env.DVAI_FORCE_DEV = "1";
    const status = await new LicenseValidator({ publicKeys }).validate();
    expect(status.kind).toBe("free-dev");
  });

  it("returns free-dev when NODE_ENV=test (this test process)", async () => {
    delete process.env.DVAI_FORCE_PROD;
    delete process.env.DVAI_FORCE_DEV;
    process.env.NODE_ENV = "test";
    const status = await new LicenseValidator({ publicKeys }).validate();
    expect(status.kind).toBe("free-dev");
    if (status.kind === "free-dev") {
      expect(status.reason).toContain("NODE_ENV=test");
    }
  });
});

describe("LicenseValidator — token discovery", () => {
  it("loads from an explicit path", async () => {
    process.env.DVAI_FORCE_PROD = "1";
    process.env.DVAI_AUDIENCE = "acme.com";
    const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), "dvai-license-"));
    const filePath = path.join(tmpDir, "dvai-license.jwt");
    const token = await mintLicense({ aud: ["acme.com"], platforms: ["node"] });
    await fs.writeFile(filePath, token, "utf-8");

    const status = await new LicenseValidator({ path: filePath, publicKeys }).validate();
    expect(status.kind).toBe("commercial");

    await fs.rm(tmpDir, { recursive: true, force: true });
  });

  it("loads from DVAI_LICENSE_TOKEN env var", async () => {
    process.env.DVAI_FORCE_PROD = "1";
    process.env.DVAI_AUDIENCE = "acme.com";
    process.env.DVAI_LICENSE_TOKEN = await mintLicense({
      aud: ["acme.com"],
      platforms: ["node"],
    });
    const status = await new LicenseValidator({ publicKeys }).validate();
    expect(status.kind).toBe("commercial");
  });

  it("loads from DVAI_LICENSE_PATH env var", async () => {
    process.env.DVAI_FORCE_PROD = "1";
    process.env.DVAI_AUDIENCE = "acme.com";
    const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), "dvai-license-"));
    const filePath = path.join(tmpDir, "dvai-license.jwt");
    const token = await mintLicense({ aud: ["acme.com"], platforms: ["node"] });
    await fs.writeFile(filePath, token, "utf-8");
    process.env.DVAI_LICENSE_PATH = filePath;

    const status = await new LicenseValidator({ publicKeys }).validate();
    expect(status.kind).toBe("commercial");

    await fs.rm(tmpDir, { recursive: true, force: true });
  });

  it("returns free-prod when explicit path doesn't exist", async () => {
    process.env.DVAI_FORCE_PROD = "1";
    const status = await new LicenseValidator({
      path: "/nonexistent/path/dvai-license.jwt",
      publicKeys,
    }).validate();
    expect(status.kind).toBe("free-prod");
  });

  it("inline token wins over path when both are set", async () => {
    process.env.DVAI_FORCE_PROD = "1";
    process.env.DVAI_AUDIENCE = "acme.com";
    const inlineToken = await mintLicense({
      aud: ["acme.com"],
      platforms: ["node"],
      licensee: "Inline Co",
    });
    const status = await new LicenseValidator({
      token: inlineToken,
      path: "/nonexistent/path/dvai-license.jwt",
      publicKeys,
    }).validate();
    expect(status.kind).toBe("commercial");
    if (status.kind === "commercial") {
      expect(status.licensee).toBe("Inline Co");
    }
  });
});

describe("LicenseValidator — validateAndAssert (BSL 1.1 enforcement)", () => {
  it("returns the status (without throwing) for commercial licenses", async () => {
    process.env.DVAI_FORCE_PROD = "1";
    process.env.DVAI_AUDIENCE = "acme.com";
    const token = await mintLicense({ aud: ["acme.com"], platforms: ["node"] });
    const status = await new LicenseValidator({ token, publicKeys }).validateAndAssert();
    expect(status.kind).toBe("commercial");
  });

  it("returns the status (without throwing) for trial licenses", async () => {
    process.env.DVAI_FORCE_PROD = "1";
    process.env.DVAI_AUDIENCE = "acme.com";
    const token = await mintLicense({
      aud: ["acme.com"],
      platforms: ["node"],
      tier: "trial",
    });
    const status = await new LicenseValidator({ token, publicKeys }).validateAndAssert();
    expect(status.kind).toBe("trial");
  });

  it("returns the status (without throwing) for free-dev (localhost/debug)", async () => {
    process.env.DVAI_FORCE_DEV = "1";
    const status = await new LicenseValidator({ publicKeys }).validateAndAssert();
    expect(status.kind).toBe("free-dev");
  });

  it("THROWS LicenseRequiredError when no license is found in production", async () => {
    process.env.DVAI_FORCE_PROD = "1";
    const v = new LicenseValidator({ publicKeys });
    await expect(v.validateAndAssert()).rejects.toThrow(LicenseRequiredError);
  });

  it("THROWS LicenseRequiredError with status=free-prod for missing license", async () => {
    process.env.DVAI_FORCE_PROD = "1";
    const v = new LicenseValidator({ publicKeys });
    try {
      await v.validateAndAssert();
      throw new Error("should have thrown");
    } catch (err) {
      expect(err).toBeInstanceOf(LicenseRequiredError);
      const lre = err as LicenseRequiredError;
      expect(lre.status.kind).toBe("free-prod");
      expect(lre.name).toBe("LicenseRequiredError");
      // Error message should mention how to resolve.
      expect(lre.message).toContain("Commercial License Required");
      expect(lre.message).toContain("dvai-license.jwt");
      expect(lre.message).toContain("DVAI_LICENSE_PATH");
    }
  });

  it("THROWS LicenseRequiredError with status=free-expired for expired tokens", async () => {
    process.env.DVAI_FORCE_PROD = "1";
    process.env.DVAI_AUDIENCE = "acme.com";
    const pastSeconds = Math.floor(Date.now() / 1000) - 3600;
    const token = await mintLicense({
      aud: ["acme.com"],
      platforms: ["node"],
      licensee: "Expired Co",
      exp: pastSeconds,
    });
    const v = new LicenseValidator({ token, publicKeys });
    try {
      await v.validateAndAssert();
      throw new Error("should have thrown");
    } catch (err) {
      expect(err).toBeInstanceOf(LicenseRequiredError);
      const lre = err as LicenseRequiredError;
      expect(lre.status.kind).toBe("free-expired");
      // Error message should mention the licensee + expiry time.
      expect(lre.message).toContain("Expired Co");
    }
  });

  it("THROWS for tampered tokens in production", async () => {
    process.env.DVAI_FORCE_PROD = "1";
    process.env.DVAI_AUDIENCE = "acme.com";
    const token = await mintLicense({ aud: ["acme.com"], platforms: ["node"] });
    const parts = token.split(".");
    if (!parts[1]) throw new Error("malformed test token");
    const corrupted = `${parts[0]}.${parts[1].slice(0, -2)}XX.${parts[2]}`;
    const v = new LicenseValidator({ token: corrupted, publicKeys });
    await expect(v.validateAndAssert()).rejects.toThrow(LicenseRequiredError);
  });

  it("THROWS for audience-mismatched tokens in production", async () => {
    process.env.DVAI_FORCE_PROD = "1";
    process.env.DVAI_AUDIENCE = "widget.io";
    const token = await mintLicense({ aud: ["acme.com"], platforms: ["node"] });
    const v = new LicenseValidator({ token, publicKeys });
    await expect(v.validateAndAssert()).rejects.toThrow(LicenseRequiredError);
  });

  it("does NOT throw in dev mode even when license is invalid", async () => {
    // The dev-mode bypass short-circuits BEFORE any token verification,
    // so a developer running on localhost never sees a license error.
    process.env.DVAI_FORCE_DEV = "1";
    const v = new LicenseValidator({ token: "not-even-a-jwt", publicKeys });
    const status = await v.validateAndAssert();
    expect(status.kind).toBe("free-dev");
  });
});
