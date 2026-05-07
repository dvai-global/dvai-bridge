import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { promises as fs } from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import {
  MultiTenantPairing,
  MultiTenantPairingError,
  type OffloadAudit,
  type PairingRequest,
} from "../peer-mode/MultiTenantPairing.js";

let tmpDir: string;

beforeEach(async () => {
  tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), "dvai-hub-mtp-test-"));
});

afterEach(async () => {
  await fs.rm(tmpDir, { recursive: true, force: true });
});

function newStore(opts?: {
  approve?: boolean | ((req: PairingRequest) => boolean);
  allowedAppIds?: string[];
  expireAfterDays?: number;
}) {
  const approve = opts?.approve ?? true;
  return new MultiTenantPairing({
    storeDir: tmpDir,
    allowedAppIds: opts?.allowedAppIds,
    expireAfterDays: opts?.expireAfterDays,
    onPairingRequest: async (req) => {
      if (typeof approve === "function") return approve(req);
      return approve;
    },
  });
}

const REQ_A: PairingRequest = {
  peerDeviceId: "phone-A",
  peerDeviceName: "iPhone A",
  appId: "com.example.chatapp",
  appName: "Chat App",
  dvaiVersion: "3.1.0",
};

const REQ_B: PairingRequest = {
  peerDeviceId: "phone-B",
  peerDeviceName: "iPhone B",
  appId: "com.example.journal",
  appName: "Journal",
  dvaiVersion: "3.1.0",
};

describe("MultiTenantPairing — approval flow", () => {
  it("calls onPairingRequest exactly once for a fresh peer", async () => {
    let calls = 0;
    const store = new MultiTenantPairing({
      storeDir: tmpDir,
      onPairingRequest: async () => {
        calls++;
        return true;
      },
    });
    const p = await store.approveOrFetch(REQ_A);
    expect(calls).toBe(1);
    expect(p.peerDeviceId).toBe("phone-A");
    expect(p.appId).toBe("com.example.chatapp");
    expect(p.pairingKey).toMatch(/^[A-Za-z0-9_-]{40,}$/);
  });

  it("re-uses an existing pairing without re-prompting", async () => {
    let calls = 0;
    const store = new MultiTenantPairing({
      storeDir: tmpDir,
      onPairingRequest: async () => {
        calls++;
        return true;
      },
    });
    const p1 = await store.approveOrFetch(REQ_A);
    const p2 = await store.approveOrFetch(REQ_A);
    expect(calls).toBe(1);
    expect(p1.pairingKey).toBe(p2.pairingKey);
    expect(p2.lastUsedAt).toBeGreaterThanOrEqual(p1.lastUsedAt);
  });

  it("throws 'denied' when the user rejects approval", async () => {
    const store = newStore({ approve: false });
    await expect(store.approveOrFetch(REQ_A)).rejects.toBeInstanceOf(
      MultiTenantPairingError,
    );
    await expect(store.approveOrFetch(REQ_A)).rejects.toMatchObject({ code: "denied" });
  });

  it("rejects synchronously when appId is not in allowedAppIds (Flavor 2 lockdown)", async () => {
    const store = newStore({ allowedAppIds: ["com.allowed.only"] });
    await expect(store.approveOrFetch(REQ_A)).rejects.toMatchObject({
      code: "app_not_allowed",
    });
  });

  it("permits an allowed appId when allowedAppIds is set", async () => {
    const store = newStore({ allowedAppIds: ["com.example.chatapp"] });
    const p = await store.approveOrFetch(REQ_A);
    expect(p.appId).toBe("com.example.chatapp");
  });
});

describe("MultiTenantPairing — tenant isolation", () => {
  it("two apps pair concurrently with independent keys", async () => {
    const store = newStore();
    const [pA, pB] = await Promise.all([
      store.approveOrFetch(REQ_A),
      store.approveOrFetch(REQ_B),
    ]);
    expect(pA.pairingKey).not.toBe(pB.pairingKey);
    expect(pA.appId).not.toBe(pB.appId);
  });

  it("revoking one app's pairing does not affect the other", async () => {
    const store = newStore();
    await store.approveOrFetch(REQ_A);
    await store.approveOrFetch(REQ_B);
    await store.revoke(REQ_A.appId, REQ_A.peerDeviceId);
    const listA = await store.listForApp(REQ_A.appId);
    const listB = await store.listForApp(REQ_B.appId);
    expect(listA).toEqual([]);
    expect(listB.length).toBe(1);
    expect(listB[0]?.peerDeviceId).toBe("phone-B");
  });

  it("revokeAll clears one app's pairings only", async () => {
    const store = newStore();
    await store.approveOrFetch(REQ_A);
    await store.approveOrFetch({ ...REQ_A, peerDeviceId: "phone-A2", peerDeviceName: "iPad" });
    await store.approveOrFetch(REQ_B);
    await store.revokeAll(REQ_A.appId);
    expect(await store.listForApp(REQ_A.appId)).toEqual([]);
    expect((await store.listForApp(REQ_B.appId)).length).toBe(1);
  });

  it("listAll() returns pairings across every app", async () => {
    const store = newStore();
    await store.approveOrFetch(REQ_A);
    await store.approveOrFetch(REQ_B);
    const all = await store.listAll();
    expect(all.length).toBe(2);
    expect(new Set(all.map((p) => p.appId))).toEqual(
      new Set(["com.example.chatapp", "com.example.journal"]),
    );
  });
});

describe("MultiTenantPairing — expiry", () => {
  it("findActivePairing returns undefined for an expired pairing", async () => {
    const store = newStore({ expireAfterDays: 30 });
    const p = await store.approveOrFetch(REQ_A);
    // Force expiry by rewriting the pairings file with a stale lastUsedAt.
    const file = path.join(
      tmpDir,
      "apps",
      REQ_A.appId.replace(/[^a-zA-Z0-9._-]/g, "_"),
      "pairings.json",
    );
    const stale = [
      { ...p, lastUsedAt: Date.now() - 31 * 24 * 60 * 60 * 1000 },
    ];
    await fs.writeFile(file, JSON.stringify(stale, null, 2), "utf8");
    expect(
      await store.findActivePairing(REQ_A.appId, REQ_A.peerDeviceId),
    ).toBeUndefined();
  });

  it("approveOrFetch re-prompts after expiry", async () => {
    let calls = 0;
    const store = new MultiTenantPairing({
      storeDir: tmpDir,
      expireAfterDays: 30,
      onPairingRequest: async () => {
        calls++;
        return true;
      },
    });
    const p1 = await store.approveOrFetch(REQ_A);
    expect(calls).toBe(1);

    // Mark stale
    const file = path.join(
      tmpDir,
      "apps",
      REQ_A.appId.replace(/[^a-zA-Z0-9._-]/g, "_"),
      "pairings.json",
    );
    const stale = [{ ...p1, lastUsedAt: Date.now() - 31 * 24 * 60 * 60 * 1000 }];
    await fs.writeFile(file, JSON.stringify(stale, null, 2), "utf8");

    const p2 = await store.approveOrFetch(REQ_A);
    expect(calls).toBe(2);
    expect(p2.pairingKey).not.toBe(p1.pairingKey);
  });
});

describe("MultiTenantPairing — audit log", () => {
  function audit(appId: string, extras: Partial<OffloadAudit> = {}): OffloadAudit {
    return {
      ts: new Date().toISOString(),
      appId,
      peerDeviceId: "phone-A",
      engine: "builtin",
      requestedModel: "gemma-2-2b-it",
      servedModel: "gemma-2-2b-it",
      outcome: "exact",
      ...extras,
    };
  }

  it("records and reads back audit entries per-app", async () => {
    const store = newStore();
    await store.recordAudit(REQ_A.appId, audit(REQ_A.appId));
    await store.recordAudit(REQ_A.appId, audit(REQ_A.appId, { outcome: "substituted", reason: "better_quant" }));
    await store.recordAudit(REQ_B.appId, audit(REQ_B.appId));

    const auditA = await store.getAppAudit(REQ_A.appId);
    const auditB = await store.getAppAudit(REQ_B.appId);
    expect(auditA.length).toBe(2);
    expect(auditB.length).toBe(1);
    expect(auditA[1]?.outcome).toBe("substituted");
  });

  it("limit option returns the most-recent N entries", async () => {
    const store = newStore();
    for (let i = 0; i < 5; i++) {
      await store.recordAudit(REQ_A.appId, audit(REQ_A.appId, { servedModel: `model-${i}` }));
    }
    const recent2 = await store.getAppAudit(REQ_A.appId, 2);
    expect(recent2.length).toBe(2);
    expect(recent2[1]?.servedModel).toBe("model-4");
  });

  it("rejects audit entries whose appId doesn't match the recordAudit appId", async () => {
    const store = newStore();
    await expect(
      store.recordAudit(REQ_A.appId, audit(REQ_B.appId)),
    ).rejects.toMatchObject({ code: "audit_app_mismatch" });
  });

  it("garbage-collects audit entries older than auditRetentionDays", async () => {
    const store = new MultiTenantPairing({
      storeDir: tmpDir,
      auditRetentionDays: 30,
      onPairingRequest: async () => true,
    });

    // Pre-seed the audit file with one ancient and one fresh entry.
    const appDir = path.join(
      tmpDir,
      "apps",
      REQ_A.appId.replace(/[^a-zA-Z0-9._-]/g, "_"),
    );
    await fs.mkdir(appDir, { recursive: true });
    const ancient = audit(REQ_A.appId, {
      ts: new Date(Date.now() - 60 * 24 * 60 * 60 * 1000).toISOString(),
      servedModel: "old-entry",
    });
    const fresh = audit(REQ_A.appId, { servedModel: "new-entry" });
    await fs.writeFile(
      path.join(appDir, "audit.log"),
      JSON.stringify(ancient) + "\n" + JSON.stringify(fresh) + "\n",
      "utf8",
    );

    // Recording any new entry triggers GC.
    await store.recordAudit(REQ_A.appId, audit(REQ_A.appId, { servedModel: "newest-entry" }));
    const log = await store.getAppAudit(REQ_A.appId);
    expect(log.find((e) => e.servedModel === "old-entry")).toBeUndefined();
    expect(log.find((e) => e.servedModel === "new-entry")).toBeDefined();
    expect(log.find((e) => e.servedModel === "newest-entry")).toBeDefined();
  });
});

describe("MultiTenantPairing — sanitization", () => {
  it("permits unusual appId characters by sanitizing the directory name", async () => {
    const store = newStore();
    const weirdReq: PairingRequest = {
      ...REQ_A,
      appId: "weird/app:id-with$chars",
    };
    const p = await store.approveOrFetch(weirdReq);
    expect(p.appId).toBe("weird/app:id-with$chars");
    // Should be retrievable by the original appId
    const list = await store.listForApp("weird/app:id-with$chars");
    expect(list.length).toBe(1);
  });
});
