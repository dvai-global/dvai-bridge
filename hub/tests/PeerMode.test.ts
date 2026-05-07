import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { promises as fs } from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import { parseModelName } from "../peer-mode/ModelParser.js";
import { PeerMode } from "../peer-mode/PeerMode.js";
import type {
  EngineAdapter,
  ChatRequest,
  ChatResponse,
} from "../peer-mode/EngineBridge.js";
import type { BackendDescriptor } from "../peer-mode/SubstitutionPolicy.js";

let tmpDir: string;

beforeEach(async () => {
  tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), "dvai-hub-peermode-"));
});

afterEach(async () => {
  await fs.rm(tmpDir, { recursive: true, force: true });
});

function backend(modelString: string, engine = "builtin"): BackendDescriptor {
  return {
    descriptor: parseModelName(modelString),
    engine,
    engineModelId: modelString,
  };
}

function fakeOllama(models: string[]): EngineAdapter {
  return {
    name: "ollama",
    detect: async () => true,
    enumerateCachedModels: async () =>
      models.map((m) => backend(m, "ollama")),
    serveRequest: async (_d, _req: ChatRequest): Promise<ChatResponse> => ({
      status: 200,
      headers: {},
      body: { ok: true },
    }),
    close: async () => undefined,
  };
}

describe("PeerMode — lifecycle", () => {
  it("starts and stops cleanly", async () => {
    const peer = new PeerMode({
      storeDir: tmpDir,
      externalEnginesEnabled: false,
      onPairingRequest: async () => true,
    });
    const status = await peer.start();
    expect(status.running).toBe(true);
    expect(status.startedAt).toBeGreaterThan(0);
    await peer.stop();
    expect(peer.getStatus().running).toBe(false);
  });

  it("setServerInfo merges the embedded HTTP server's bind info", async () => {
    const peer = new PeerMode({
      storeDir: tmpDir,
      externalEnginesEnabled: false,
      onPairingRequest: async () => true,
    });
    await peer.start();
    const status = peer.setServerInfo({ port: 38883, baseUrl: "http://127.0.0.1:38883" });
    expect(status.port).toBe(38883);
    expect(status.baseUrl).toBe("http://127.0.0.1:38883");
    expect(peer.getStatus().baseUrl).toBe("http://127.0.0.1:38883");
  });

  it("start() is idempotent", async () => {
    const peer = new PeerMode({
      storeDir: tmpDir,
      externalEnginesEnabled: false,
      onPairingRequest: async () => true,
    });
    await peer.start();
    const startedAt = peer.getStatus().startedAt;
    await peer.start();
    expect(peer.getStatus().startedAt).toBe(startedAt);
  });
});

describe("PeerMode — pairing pass-through", () => {
  it("forwards approveOrFetchPairing to the multi-tenant store", async () => {
    let callCount = 0;
    const peer = new PeerMode({
      storeDir: tmpDir,
      externalEnginesEnabled: false,
      onPairingRequest: async () => {
        callCount++;
        return true;
      },
    });
    await peer.start();
    const pairing = await peer.approveOrFetchPairing({
      peerDeviceId: "phone-A",
      peerDeviceName: "iPhone A",
      appId: "com.example.app",
      dvaiVersion: "3.1.0",
    });
    expect(callCount).toBe(1);
    expect(pairing.appId).toBe("com.example.app");

    // Same request again — should hit the cache.
    await peer.approveOrFetchPairing({
      peerDeviceId: "phone-A",
      peerDeviceName: "iPhone A",
      appId: "com.example.app",
      dvaiVersion: "3.1.0",
    });
    expect(callCount).toBe(1);
  });

  it("listAllPairings spans both apps", async () => {
    const peer = new PeerMode({
      storeDir: tmpDir,
      externalEnginesEnabled: false,
      onPairingRequest: async () => true,
    });
    await peer.start();
    await peer.approveOrFetchPairing({
      peerDeviceId: "p1",
      peerDeviceName: "P1",
      appId: "app.a",
      dvaiVersion: "3.1.0",
    });
    await peer.approveOrFetchPairing({
      peerDeviceId: "p2",
      peerDeviceName: "P2",
      appId: "app.b",
      dvaiVersion: "3.1.0",
    });
    expect((await peer.listAllPairings()).length).toBe(2);
    expect((await peer.listPairingsForApp("app.a")).length).toBe(1);
  });

  it("revokePairing removes only the named pairing", async () => {
    const peer = new PeerMode({
      storeDir: tmpDir,
      externalEnginesEnabled: false,
      onPairingRequest: async () => true,
    });
    await peer.start();
    await peer.approveOrFetchPairing({
      peerDeviceId: "p1",
      peerDeviceName: "P1",
      appId: "app.a",
      dvaiVersion: "3.1.0",
    });
    await peer.approveOrFetchPairing({
      peerDeviceId: "p2",
      peerDeviceName: "P2",
      appId: "app.a",
      dvaiVersion: "3.1.0",
    });
    await peer.revokePairing("app.a", "p1");
    const remaining = await peer.listPairingsForApp("app.a");
    expect(remaining.length).toBe(1);
    expect(remaining[0]?.peerDeviceId).toBe("p2");
  });
});

describe("PeerMode — request routing", () => {
  it("routes exact-matching local backend without consulting external engines", async () => {
    const peer = new PeerMode({
      storeDir: tmpDir,
      externalEnginesEnabled: false,
      onPairingRequest: async () => true,
    });
    await peer.start();
    peer.setLocalBackends([backend("Llama-3.2-3B-Instruct-Q4_K_M", "builtin")]);
    const decision = await peer.routeRequest(parseModelName("Llama-3.2-3B-Instruct-Q4_K_M"));
    expect(decision.kind).toBe("exact");
    if (decision.kind === "exact") {
      expect(decision.backend.engine).toBe("builtin");
    }
  });

  it("falls through to external engines when local has no match", async () => {
    const peer = new PeerMode({
      storeDir: tmpDir,
      externalEnginesEnabled: true,
      engineAdapters: [fakeOllama(["llama3.2:3b"])],
      onPairingRequest: async () => true,
    });
    await peer.start();
    peer.setLocalBackends([backend("gemma-2-2b-it-q4_K_M", "builtin")]);
    // Test: ask for the Ollama-cached model
    const req = parseModelName("llama3.2:3b");
    const decision = await peer.routeRequest(req);
    expect(decision.kind).toBe("exact");
    if (decision.kind === "exact") {
      expect(decision.backend.engine).toBe("ollama");
    }
  });

  it("refuses on type mismatch even when ollama has the same family/size", async () => {
    const peer = new PeerMode({
      storeDir: tmpDir,
      externalEnginesEnabled: true,
      engineAdapters: [fakeOllama(["llama3.2:3b"])],
      onPairingRequest: async () => true,
    });
    await peer.start();
    // Request a "code"-typed model but only an instruct-typed is cached.
    const decision = await peer.routeRequest(parseModelName("Llama-3.2-3B-Code-Q4_K_M"));
    expect(decision.kind).toBe("refuse");
    if (decision.kind === "refuse") {
      // Ollama's `llama3.2:3b` parses to type="unknown" (no type token) — so
      // the closest mismatch reason is type_mismatch (other fields match).
      expect(decision.reason).toBe("type_mismatch");
    }
  });

  it("substitutes a better quant when preferBetterQuant=true", async () => {
    const peer = new PeerMode({
      storeDir: tmpDir,
      externalEnginesEnabled: false,
      onPairingRequest: async () => true,
      preferBetterQuant: true,
    });
    await peer.start();
    peer.setLocalBackends([backend("Llama-3.2-3B-Instruct-Q8_0", "builtin")]);
    const decision = await peer.routeRequest(
      parseModelName("Llama-3.2-3B-Instruct-Q4_K_M"),
    );
    expect(decision.kind).toBe("substituted");
    if (decision.kind === "substituted") {
      expect(decision.reason).toBe("better_quant");
      expect(decision.backend.descriptor.quant).toBe("q8_0");
    }
  });

  it("strict-by-default refuses quant mismatch (preferBetterQuant unset)", async () => {
    const peer = new PeerMode({
      storeDir: tmpDir,
      externalEnginesEnabled: false,
      onPairingRequest: async () => true,
    });
    await peer.start();
    peer.setLocalBackends([backend("Llama-3.2-3B-Instruct-Q8_0", "builtin")]);
    const decision = await peer.routeRequest(
      parseModelName("Llama-3.2-3B-Instruct-Q4_K_M"),
    );
    expect(decision.kind).toBe("refuse");
    if (decision.kind === "refuse") {
      expect(decision.reason).toBe("quant_mismatch_strict");
    }
  });
});

describe("PeerMode — audit surface + dashboard status", () => {
  it("recordOffloadAudit lands in the per-app audit log + fires onOffloadServed", async () => {
    const seen: string[] = [];
    const peer = new PeerMode({
      storeDir: tmpDir,
      externalEnginesEnabled: false,
      onPairingRequest: async () => true,
      onOffloadServed: (a) => seen.push(a.servedModel),
    });
    await peer.start();
    await peer.recordOffloadAudit({
      ts: new Date().toISOString(),
      appId: "com.example.app",
      peerDeviceId: "phone-A",
      engine: "builtin",
      requestedModel: "gemma:2b",
      servedModel: "gemma-2-2b-it",
      outcome: "exact",
    });
    expect(seen).toEqual(["gemma-2-2b-it"]);
    const log = await peer.getAppAudit("com.example.app");
    expect(log.length).toBe(1);
    expect(log[0]?.outcome).toBe("exact");
  });

  it("getDetectedEngines returns adapter status snapshots", async () => {
    const peer = new PeerMode({
      storeDir: tmpDir,
      externalEnginesEnabled: true,
      engineAdapters: [fakeOllama(["llama3.2:1b", "gemma:2b"])],
      onPairingRequest: async () => true,
    });
    await peer.start();
    const summary = peer.getDetectedEngines();
    expect(summary.length).toBe(1);
    expect(summary[0]?.name).toBe("ollama");
    expect(summary[0]?.detected).toBe(true);
    expect(summary[0]?.modelCount).toBe(2);
  });

  it("findEngineAdapter forwards from the bridge", async () => {
    const adapter = fakeOllama([]);
    const peer = new PeerMode({
      storeDir: tmpDir,
      externalEnginesEnabled: true,
      engineAdapters: [adapter],
      onPairingRequest: async () => true,
    });
    await peer.start();
    expect(peer.findEngineAdapter("ollama")).toBe(adapter);
    expect(peer.findEngineAdapter("missing")).toBeUndefined();
  });
});
